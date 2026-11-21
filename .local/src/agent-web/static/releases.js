"use strict";
// The Releases tab: every app, what is deployed where it matters most and its worst status, from
// /api/releases (hub_core::releases). The table is the shared one (table.js): the server filters
// and sorts by the view in the URL. A row opens the app's page, `#releases/apps/<name>`
// (links::Kind::App), in place of the table: its status (Gatus checks, uptime, incidents), its
// headline env's channels, the other envs in a
// fold under them, its releases, builds and changelog. A new snapshot pushes the `releases` event.
// The page is the layout's inner tabs (hub_core::layout, app.js INNER_TABS): Apps (the head, the
// table or an app's page), Release runs and Flow (swimlanes, hub_core::lanes), the strip above them.
// CI runs and Tests are Infra's.

// Only the "2m ago" changes between snapshots, so this redraws without reading.
const RELEASES_AGE_MS = 60e3;
// Which folds on the tab are open (an app's other envs, Release runs' folds), so a repaint keeps them as they were.
const REL_OPEN = {};
// What the URL has open after `apps/`: an app, or an app and a version (`dodginballs/0.5.3`, a
// release's page, hub_core::release_page), or "" on the table.
const relPage = () => pageId("releases", "apps");
const relApp = () => relPage().split("/")[0];
// A `<name>/<version>` id split at its first slash: [name, version], version "" when it has none.
const splitId = (p) => { const at = p.indexOf("/"); return at < 0 ? [p, ""] : [p.slice(0, at), p.slice(at + 1)]; };
const relVer = () => splitId(relPage())[1];
// What the URL has open after `versions/`: a project and a version (`unity-core-playground/0.5.3`,
// hub_core::version_page), or "".
const relVersion = () => pageId("releases", "versions");
const relVersionOf = () => splitId(relVersion());
// Any page in place of the table: an app's, a release's or a version's.
const relDetail = () => relPage() || relVersion();
const relst = tblTab({
  tab: "releases", id: "rel", el: "releases", api: "/api/releases", hint: "search, or stage:alpha channel:prod status:drift",
  open: () => REL_OPEN,
  // The open page's app is read whatever the view hides; its changelog is read each time its
  // page opens (a read with no app closes it), so a reopened app shows its newest tags.
  params: (p) => { if (relApp()) p.set("app", relApp()); },
  got: (t) => { const a = t.data?.app; if (!a) relOpened = null; else if (relOpened !== a.project) { relOpened = a.project; loadChangelog(a.project); } },
  draw: (html) => paint($("releases"), relDetail() ? innerStrip("releases", relFlagged()) + innerWrap("releases", "detail", relVersion() ? versionPage() : relVer() ? releasePage() : appPage(relst.data)) : html, REL_OPEN),
  head: (t) => innerStrip("releases", relFlagged()) + innerWrap("releases", "table", releasesHead(t.data)),
  lead: () => innerStrip("releases", relFlagged()),
  body: (t) => releasesBody(t.data), tiles: (t) => releasesTiles(t.data),
  wrap: (html) => innerWrap("releases", "table", html),
  tail: () => innerWrap("releases", "runs", relRuns.block()) + innerWrap("releases", "swimlanes", relFlowBlock()),
});
// The sections needing a look, the strip's counts: each read says its own (Releases::needs_look,
// Builds::needs_look on the release runs).
const relFlagged = () => [relst.data?.look && "table", relRuns.data?.look && "runs"].filter(Boolean);

const relKey = (a) => a.project;
// A cell whose words say the fact is absent (releases::BLANKS, sent as `blanks`) is dimmed.
const relDim = (text, cls = "") => [cls, (relst.data?.blanks || []).includes(text) ? "muted" : ""].filter(Boolean).join(" ");
// The app whose page last opened, so its changelog is read once per opening.
let relOpened = null;
// The channel whose detail is open inside an opened app, `project|id`.
let relCh = null;
const chKey = (r) => `${r.project}|${r.id}`;

const REL_COLS = { project: ["app"], stage: ["stage"], live: ["deployed"], status: ["status"], checks: ["checks"], channels: ["channels"], released: ["released"], last_deploy: ["last deploy"] };

// One app; the name goes to its Projects card, the rest of the row to its page.
function releaseRow(a, i) {
  const project = tblLinks(relst.data?.table, i).project;
  return `<tr class="jr" data-key="${esc(relKey(a))}"><td>${tblLink(project, a.project)}</td>` +
    `<td class="${levelClass(a.stage_level) || "muted"}" title="${esc(a.stage_text)}">${esc(a.stage || "-")}</td>` +
    `<td class="${relDim(a.live_text, "wrap")}">${esc(a.live_text)}</td><td class="${levelClass(a.level)}">${esc(a.status_text)}</td>` +
    `<td class="${a.checks.says === "no check" ? "muted" : levelClass(a.checks.level)}">${esc(a.checks.says)}</td>` +
    `<td class="wrap${a.unread ? " warn" : ""}">${esc(a.channels_text)}</td><td class="${relDim(a.released_text)}">${esc(a.released_text)}</td>` +
    `<td class="${relDim(a.last_deploy_text, levelClass(a.deploy_level))}">${esc(a.last_deploy_text)}</td></tr>`;
}

// One channel of an opened app; its own detail opens under it on a click.
function channelRow(r) {
  const open = chKey(r) === relCh;
  const where = r.status_text === NOT_READ ? `<span class="warn">${esc(r.live.error || r.pinned.error || "")}</span>` : esc(r.where || "");
  const row = `<tr class="rc${open ? " sel" : ""}" data-ch="${esc(chKey(r))}"><td>${esc(r.channel)}</td><td class="wrap">${esc(r.id)}</td>` +
    `<td class="${r.status === "drift" ? "bad" : ""}">${esc(r.live_text)}</td><td>${esc(r.pinned_text)}</td>` +
    `<td class="${levelClass(r.status_level)}">${esc(r.status_text)}</td><td class="wrap muted">${where}</td></tr>`;
  return open ? row + releaseDetail(r) : row;
}

const CH_HEAD = '<tr><th data-role="lead">channel</th><th>id</th><th data-role="glance" data-named>deployed</th><th>pinned</th><th data-role="glance">status</th><th data-role="glance">where</th></tr>';
const chTable = (rows) => `<div class="scroll"><table class="tbl">${CH_HEAD}${rows.map(channelRow).join("")}</table></div>`;

// An app's page: its header with the way back to the table and to its Projects card, its status
// (appStatus), then its headline env's channels, the other envs in a fold that starts open, its release history, its
// builds and what the picked tag shipped. An app the snapshot does not have says so.
function appPage(d) {
  const name = relApp(), view = st.views.releases;
  const back = `<a class="btn sm" href="#releases/${ENTITY_PAGES.releases.apps}${view ? "?" + view : ""}">All apps</a>`;
  const errs = [relst.err, ...(d?.errors || [])].filter(Boolean);
  const down = errs.length ? `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>` : "";
  // A read asked for another app (or none) is still the old page's: wait for this one's.
  if (d?.asked !== name) return `<div class="bhead"><span>Releases / ${esc(name)}</span>${back}</div>${down}<div class="empty">reading...</div>`;
  const a = d.app;
  if (!a) return `<div class="bhead"><span>Releases / ${esc(name)}</span>${back}</div>${down}<div class="empty">No such app: ${esc(name)}.</div>`;
  const project = d.app_links?.project ? ` <a class="btn sm" href="${esc(d.app_links.project)}">Project page</a>` : "";
  return `<div class="bhead"><span>Releases / <b>${esc(a.project)}</b> <span class="${levelClass(a.level)}">${esc(a.status_text)}</span></span><span>${back}${project}</span></div>` +
    `${down}${appStatus()}${secHead("", "Channels")}<div class="panel">${appDetail(a)}</div>`;
}

function appDetail(a) {
  const lead = a.channels.slice(0, a.lead), rest = a.channels.slice(a.lead);
  const others = rest.length
    ? cfold(`rel-env:${a.project}`, `<b>${rest.length} other channel${rest.length === 1 ? "" : "s"}</b> <span class="muted">${esc(a.others_text)}</span>`, chTable(rest), REL_OPEN, true)
    : "";
  const stage = `<div class="cline"><b>Stage</b> <span class="${levelClass(a.stage_level) || "muted"}">${esc(a.stage_text)}</span></div>` +
    (a.coverage_text ? `<div class="cline"><b>Coverage</b> <span class="muted">${esc(a.coverage_text)}</span></div>` : "");
  return `<div class="sdet">${stage}${chTable(lead)}${others}${releaseHistory(a)}${appBuilds(a)}` +
    `<div class="cline"><b>Changelog</b> ${releaseChangelog(a)}</div></div>`;
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
    `<td><a href="${esc(s.href)}" title="this release as a pipeline">${esc(s.tag)}</a></td><td class="n">${esc(s.at_text)}</td><td class="muted">${esc(s.prev_text)}</td>` +
    `<td class="wrap${s.reached.length ? "" : " muted"}">${esc(s.reached_text)}</td>` +
    `<td class="wrap${s.prs.length ? "" : " muted"}">${esc(s.prs_text)}</td><td class="wrap${s.rows.length ? "" : " muted"}">${esc(s.rows_text)}</td></tr>`).join("");
  const body = `<div class="scroll"><table class="tbl"><tr><th data-role="lead">release</th><th class="n" data-role="glance" data-named>released</th><th>prev</th><th data-role="glance">reached</th><th>prs</th><th>rows</th></tr>${rows}</table></div>`;
  return cfold(`rel-hist:${a.project}`, `<b>Releases</b> <span class="muted">${h.length} ${esc(LINE_SAYS[a.line] || "tags")}</span>`, body, REL_OPEN, true);
}

// The opened app's build runs, newest first (hub_core::releases::AppBuild): each run the release
// graph joins to one of its tags, whether it is queued, running, failed or shipped.
function appBuilds(a) {
  const b = a.builds || [];
  if (!b.length) return `<div class="cline"><b>Builds</b> <span class="muted">no build run joined to a tag in the last 30 days</span></div>`;
  const rows = b.map((x) => `<tr><td>${esc(x.tag)}</td><td>${esc(x.workflow)}</td><td class="${levelClass(x.level)}">${esc(x.state_text)}</td>` +
    `<td class="n">${esc(x.started_text)}</td><td class="n${x.live ? " muted" : ""}">${esc(x.ended_text)}</td>` +
    `<td>${/^https:/.test(x.url || "") ? `<a href="${esc(x.url)}" target="_blank" rel="noopener">run</a>` : ""}</td></tr>`).join("");
  const live = b.filter((x) => x.live).length;
  const body = `<div class="scroll"><table class="tbl"><tr><th data-role="lead">tag</th><th>workflow</th><th data-role="glance">state</th><th class="n" data-role="glance">started</th><th class="n">finished</th><th>link</th></tr>${rows}</table></div>`;
  return cfold(`rel-builds:${a.project}`, `<b>Builds</b> <span class="muted">${b.length} run${b.length === 1 ? "" : "s"}${live ? `, ${live} in progress` : ""}</span>`, body, REL_OPEN, true);
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
    line("Prev", esc(r.prev_text)) + line("Last deploy", r.deploys.last ? esc(r.last_deploy_text) : "") +
    line("Deploys", r.deploys.error ? `<span class="warn">${esc(r.deploys.error)} (${esc(r.deploys.source)})</span>` : r.deploys.history.map(releaseDeploy).join("")) +
    line("Watches", r.telemetry.map(releaseWatch).join("")) + line("Deps", r.deps.length ? esc(r.deps_text) : "") + `</div></td></tr>`;
}

// The apps, then how full each history column is (Releases::coverage) in a fold that starts shut.
function releasesBody(d) {
  const t = d.table, rows = d.rows || [];
  const cover = d.coverage ? cfold("rel-coverage", "Coverage", `<div class="cline">${esc(d.coverage)}</div>`, REL_OPEN) : "";
  if (rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, REL_COLS)}${rows.map(releaseRow).join("")}</table></div>${cover}`;
  return `<div class="panel">${t && t.total ? "No apps match." : "No apps."}</div>${cover}`;
}

// A snapshot older than the collector's cadence is stale.
const relStale = (d) => d.at && Date.now() / 1e3 - d.at > d.stale_after;
// When the snapshot was taken, after the apps' state tiles; amber once it is stale.
const releasesTiles = (d) =>
  tile("REFRESHED", d.at ? clock(d.at * 1e3) : "-", relStale(d) ? "var(--b-stalled)" : "var(--c-other)", d.at ? `${ago(d.at)} ago` : "no snapshot read");

function releasesHead(d) {
  const t = d.table;
  let html = secHead("", "Releases", t && tblCount(t), d.gaps || relStale(d) ? "warn" : "");
  if (d.gaps) html += `<div class="cline warn">${esc(d.gaps)}</div>`;
  if (relst.err) html += `<div class="panel down">${esc(relst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}
// The Release runs inner tab: the CI runs the release graph tied to a release (Scope::Release,
// scope=release), drawn by ci.js's run table under this tab's own view keys (bq, bs, bsort, bdir).
// It draws inside this tab's page, so its render is the tab's. Every run is Infra's CI runs.
const relRuns = runsTable({
  tab: "releases", id: "relrun", el: "releases", scope: "release", title: "Release runs", folds: REL_OPEN,
  none: "No run tied to a release in 30 days.", render: () => relst.render(),
});
// The Flow inner tab: one project's CI lanes (its runs tied to no release, one lane a workflow)
// and Release lanes (each app's tags, build runs and the channels a tag reached) over 24h, 7d, 30d
// or a from-to day pair (`2026-11-10..2026-11-15`, clipped to the runs ledger's 30 days, the read
// says when it is),
// from /api/releases/lanes (hub_core::lanes). A segment opens its run's record or its app's page.
// The project and window are this page's; the read is its own, made only while Flow shows.
const relFlow = { project: "", window: "", from: "", to: "", data: null, err: null };
const REL_FLOW_COLOR = { green: "var(--idle)", red: "var(--wait)", running: "var(--accent)", queued: "var(--busy)", tag: "var(--c5)", reached: "var(--c6)" };
const relFlowColor = (k) => REL_FLOW_COLOR[k] || OTHER;
const relFlowAsked = () => new URLSearchParams({ project: relFlow.project, window: relFlow.window }).toString();
const relFlowOn = () => st.tab === "releases" && !relDetail() && innerOf("releases", st.arg)[0] === "flow";
// A read for a project or window picked since it started is dropped; a failed one keeps the last up.
// An answer missing a list relFlowBlock draws is a failed read, never drawn: drawing it throws.
const REL_FLOW_LISTS = ["projects", "windows", "keys", "ci", "release", "errors"];
const relFlowRefresh = coalesce(async () => {
  const asked = relFlowAsked();
  let data = null, err = null;
  try { data = await api("/api/releases/lanes?" + asked); } catch (e) { err = e.message; }
  if (asked !== relFlowAsked()) return;
  const missing = data ? REL_FLOW_LISTS.filter((k) => !Array.isArray(data[k])) : [];
  if (missing.length) { data = null; err = `Could not read the Flow lanes: the answer has no ${missing.join(", ")}. Retry, or check the agent-web log.`; }
  if (data) { relFlow.data = data; relFlow.project = data.project; relFlow.window = data.window; [relFlow.from, relFlow.to] = relFlowDays(data.window); }
  relFlow.err = err;
  relst.render();
});
const relFlowLanes = (d, lanes) => swimlanes(lanes.map((l) => ({ ...l, segs: l.segs.map((s) => ({ ...s, a: s.a * 1e3, b: s.b * 1e3 })) })), d.t0 * 1e3, d.t1 * 1e3, relFlowColor);
// The day pair a window names (`2026-11-10..2026-11-12`, or one day), else two empty days.
const relFlowDays = (w) => (/^\d{4}-\d{2}-\d{2}(\.\.\d{4}-\d{2}-\d{2})?$/.test(w) ? [w.slice(0, 10), w.slice(-10)] : ["", ""]);
function relFlowBlock() {
  const d = relFlow.data;
  if (!d) return secHead("", "Flow") + `<div class="${relFlow.err ? "panel down" : "empty"}">${relFlow.err ? esc(relFlow.err) : "reading..."}</div>`;
  const pick = `<select class="rel-flow" aria-label="project">${d.projects.concat(d.projects.includes(d.project) ? [] : [d.project]).map((p) => `<option${p === d.project ? " selected" : ""}>${esc(p)}</option>`).join("")}</select>`;
  const [from, to] = relFlowDays(d.window);
  // The ledger's days are the only ones with runs: the pickers reach no further back.
  const lo = new Date(Date.now() - d.keep_days * 864e5), hi = new Date();
  const ymd = (t) => `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}`;
  const lim = d.keep_days ? ` min="${ymd(lo)}" max="${ymd(hi)}"` : "";
  const days = `<span class="muted">or</span> <input type="date" class="tdate" data-flow-from value="${esc(from)}"${lim} title="from day" aria-label="from day"> <span class="muted">to</span> <input type="date" class="tdate" data-flow-to value="${esc(to)}"${lim} title="to day" aria-label="to day">`;
  const wins = `<div class="seg fseg"><span class="muted">window</span>` + d.windows.map((w) => `<button class="${w === d.window ? "on" : ""}" data-flow-win="${esc(w)}">${esc(w)}</button>`).join("") + days + `</div>`;
  let h = `<div class="cline">${pick} ${wins} ${legend(d.keys.map(([k, l]) => [l, relFlowColor(k)]))}</div>`;
  const errs = [d.clipped, relFlow.err && `refresh failed, showing the last read: ${relFlow.err}`, ...d.errors].filter(Boolean);
  if (errs.length) h += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  const part = (title, lanes, empty) => secHead("", title, lanes.length || null) + (lanes.length ? `<div class="panel">${relFlowLanes(d, lanes)}</div>` : `<div class="panel muted">${esc(empty)}</div>`);
  return h + part("CI", d.ci, d.ci_empty) + part("Release", d.release, d.release_empty);
}
// A refresh must not take the focus from either search box: the section repaints when it holds it.
const relRepaint = relst.repaint;
relst.repaint = () => relRepaint() || relRuns.repaint();
// An app page's status (hub_core::app_status), above its channels: a banner, the checks Gatus runs
// on it with their uptime, 90 days and latency, and its incidents. Gatus results reach the board
// through Prometheus, which has no push, so the open page re-reads on this cadence.
const APP_PAGE_REFRESH_MS = 60e3;
// A day bar's colours by what the day saw (dayColor). A phone shows the newest 30 (app.css).
const APP_DAY_COLOR = { none: "var(--c-other)", up: "var(--idle)", dip: "var(--busy)", down: "var(--wait)" };
// The open page, by its hash (`apps/<app>`), and its last status read.
const apst = { page: "", data: null, err: null };
// A read that lands after another page opened is dropped; a failed one keeps the last read up.
const refreshAppPage = coalesce(async () => {
  const app = relApp(), page = st.page;
  if (!app || apst.page !== page) return;
  let data = null, err = null;
  try { data = await api("/api/releases/app?app=" + encodeURIComponent(app)); } catch (e) { err = e.message; }
  if (apst.page !== page) return;
  if (data) apst.data = data;
  apst.err = err;
  if (st.page === page) relst.render();
});
// The open app's page, or the table's CHECKS column, re-read each minute while it shows.
const pollAppPage = poll("releases", () => (relVersion() ? refreshVersion() : relVer() ? refreshRelease() : relPage() ? refreshAppPage() : relst.refresh()), APP_PAGE_REFRESH_MS);

// A release's page, `#releases/apps/<app>/<version>` (hub_core::release_page): the cut on show as
// a pipeline (the tag, the runs it started, the runs those started, the channels), then every cut
// of the version with each workflow's result. A version may be one cut's tag, which draws that cut.
const rlst = { page: "", data: null, err: null };
const refreshRelease = coalesce(async () => {
  const page = st.page;
  if (!relVer() || rlst.page !== page) return;
  let data = null, err = null;
  try { data = await api(`/api/releases/release?app=${encodeURIComponent(relApp())}&version=${encodeURIComponent(relVer())}`); } catch (e) { err = e.message; }
  if (rlst.page !== page) return;
  if (data) rlst.data = data;
  rlst.err = err;
  if (st.page === page) relst.render();
});
// One run of a stage: its workflow (to its run page), state and time, then each job not green.
function relAction(a) {
  const jobs = a.jobs.filter((j) => j.state !== "green");
  const green = a.jobs.length - jobs.length;
  const job = (j) => `<div class="${j.state === "red" ? "bad" : "muted"}">${esc(j.name)} ${esc(j.state)}${j.failing ? ` at ${esc(j.failing)}` : ""}</div>`;
  return `<div class="rjob ${esc(a.state)}"><a href="${esc(a.href)}"><b>${esc(a.workflow)}</b></a> <span class="${a.state === "red" ? "bad" : "muted"}">${esc(a.state)}</span>` +
    `<div class="muted">${esc(a.started_text)}, took ${esc(a.took_text)}${/^https:/.test(a.url || "") ? ` <a href="${esc(a.url)}" target="_blank" rel="noopener">forge</a>` : ""}</div>` +
    jobs.map(job).join("") + (green ? `<div class="muted">${green} job${green === 1 ? "" : "s"} green</div>` : "") +
    (a.jobs_note ? `<div class="muted">${esc(a.jobs_note)}</div>` : "") + `</div>`;
}
// One release_page::Page's pipeline (the cut on show: tag, runs by what started them, channels)
// and its cuts table, under headings at `tag` (h2 on a release's page, h3 inside a version's).
function relPipeline(p, tag = "h2") {
  const box = `<div class="rcol"><div class="muted">Tag</div><div class="rjob"><b>${esc(p.tag)}</b><div class="muted">tagged ${esc(p.at_text)}</div>` +
    `${p.sha ? `<div class="muted">${esc(p.sha.slice(0, 9))}</div>` : ""}</div></div>`;
  const stages = p.stages.map((s) => `<div class="rcol"><div class="muted">${esc(s.label)}</div>${s.actions.map(relAction).join("")}</div>`).join("") ||
    `<div class="rcol"><div class="muted">Runs</div><div class="rjob muted">no run of this cut in the ledger</div></div>`;
  const chans = `<div class="rcol"><div class="muted">Channels</div>` + (p.channels_note ? `<div class="rjob muted">${esc(p.channels_note)}</div>` : "") +
    p.channels.map((c) => `<div class="rjob${c.reached ? " green" : ""}"><b>${esc(c.id)}</b><div class="${c.reached ? "" : "muted"}">${esc(c.text)}</div></div>`).join("") + `</div>`;
  const pipe = secHead("", "Pipeline", undefined, undefined, tag) + `<div class="panel"><div class="rgraph">${box}${stages}${chans}</div>` +
    `<div class="cline"><b>PRs</b> ${esc(p.prs_text)} <b>Rows</b> ${esc(p.rows_text)}</div></div>`;
  const wf = p.workflows.map((w) => `<th>${esc(w)}</th>`).join("");
  const res = (r) => `<td class="${r === "red" ? "bad" : r === "green" ? "" : "muted"}">${esc(r)}</td>`;
  const rows = p.cuts.map((c) => `<tr class="${c.tag === p.tag ? "sel" : ""}"><td><a href="${esc(c.href)}">${esc(c.tag)}</a></td><td class="n">${esc(c.at_text)}</td>` +
    `<td class="${levelClass(c.level)}">${esc(c.state)}</td>${c.results.map(res).join("")}<td class="wrap muted">${esc(c.reached_text)}</td><td class="wrap muted">${esc(c.prs_text)}</td></tr>`).join("");
  const cuts = secHead("", "Cuts", p.cuts.length, undefined, tag) + `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">cut</th><th class="n" data-role="glance">tagged</th>` +
    `<th data-role="glance">state</th>${wf}<th>reached</th><th>prs</th></tr>${rows}</table>${p.note ? `<div class="cline muted">${esc(p.note)}</div>` : ""}</div>`;
  return pipe + cuts;
}
function releasePage() {
  const app = relApp(), ver = relVer(), d = rlst.data, p = d?.page;
  const back = p?.app_href ? `<a class="btn sm" href="${esc(p.app_href)}">${esc(app)}</a>` : "";
  const head = (inner) => `<div class="bhead"><span>Releases / ${esc(app)} / ${inner}</span>${back}</div>`;
  const errs = [rlst.err, ...(d?.errors || [])].filter(Boolean);
  const down = errs.length ? `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>` : "";
  // The server echoes the version it was asked for, so an answer for another page is never drawn.
  if (!p || d.asked !== ver) return head(esc(ver)) + down + (rlst.err ? "" : `<div class="empty">reading...</div>`);
  const cut = p.cuts.find((c) => c.tag === p.tag) || {};
  const up = p.version_href ? `<div class="cline"><a href="${esc(p.version_href)}">every app's cut of ${esc(p.version)}, and its rows</a></div>` : "";
  return head(`<b>${esc(p.version)}</b> <span class="${levelClass(cut.level)}">${esc(cut.state || "")}</span>`) + down + up + relPipeline(p);
}

// A version's page, `#releases/versions/<project>/<version>` (hub_core::version_page): the header
// (status, newest cut, window days), a bar of its rows by state, every row aimed at it with who
// works it and its PRs, then each app's cut of it, linked to that app's release page.
const vrst = { page: "", data: null, err: null };
const refreshVersion = coalesce(async () => {
  const page = st.page, [project, version] = relVersionOf();
  if (!version || vrst.page !== page) return;
  let data = null, err = null;
  try { data = await api(`/api/releases/version?project=${encodeURIComponent(project)}&version=${encodeURIComponent(version)}`); } catch (e) { err = e.message; }
  if (vrst.page !== page) return;
  if (data) vrst.data = data;
  vrst.err = err;
  if (st.page === page) relst.render();
});
const VER_BAR = [["done", "ok"], ["doing", "doing"], ["open", ""], ["dropped", "dropped"]];
function versionPage() {
  const [project, version] = relVersionOf(), d = vrst.data, p = d?.page;
  const head = (inner) => `<div class="bhead"><span>Releases / ${p?.project_href ? `<a href="${esc(p.project_href)}">${esc(project)}</a>` : esc(project)} / ${inner}</span></div>`;
  const errs = [vrst.err, ...(d?.errors || []), ...(p?.errors || [])].filter(Boolean);
  const down = errs.length ? `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>` : "";
  if (!p) return head(esc(version)) + down + (vrst.err ? "" : `<div class="empty">reading...</div>`);
  const b = p.bar, total = b.done + b.doing + b.open + b.dropped;
  const bar = total ? `<div class="kbar">${VER_BAR.map(([k, c]) => (b[k] ? `<i class="${c}" style="flex:${b[k]}" title="${b[k]} ${k}"></i>` : "")).join("")}</div>` : "";
  const facts = `<div class="panel"><div class="cline"><b>Cut</b> ${esc(p.cut_text)} <b>Opened</b> ${esc(p.opened_text)} <b>Due</b> ${esc(p.due_text)}</div>${bar}` +
    `<div class="cline muted">${VER_BAR.map(([k]) => `${b[k]} ${k}`).join(", ")}</div></div>`;
  const pr = (c) => (c.url ? `<a href="${esc(c.url)}" target="_blank" rel="noopener">${esc(c.text)}</a>` : esc(c.text)) + (c.state ? ` <span class="muted">${esc(c.state)}</span>` : "");
  const who = (r) => (r.assignee ? `<a href="${esc(r.assignee_href)}">${esc(r.assignee)}</a> <span class="muted">${esc(r.assignee_state)}</span>` : `<span class="muted">-</span>`);
  const rows = p.rows.map((r) => `<tr><td>${r.href ? `<a href="${esc(r.href)}">${esc(r.id)}</a>` : "-"}</td><td class="wrap">${esc(r.title)}</td>` +
    `<td class="${levelClass(r.level)}">${esc(r.state)}</td><td>${esc(r.priority)}</td><td>${who(r)}</td><td class="wrap">${r.prs.map(pr).join(", ") || `<span class="muted">-</span>`}</td></tr>`).join("");
  const table = secHead("", "Rows", p.rows.length) + `<div class="panel scroll">` + (p.rows_note ? `<div class="cline muted">${esc(p.rows_note)}</div>` : "") +
    (rows ? `<table class="tbl"><tr><th data-role="lead">row</th><th>title</th><th data-role="glance">state</th><th>priority</th><th>assignee</th><th>prs</th></tr>${rows}</table>` : "") + `</div>`;
  const app = (a) => `<tr><td>${a.href ? `<a href="${esc(a.href)}">${esc(a.app)}</a>` : esc(a.app)}</td><td>${esc(a.tag || "-")}</td>` +
    `<td class="${levelClass(a.level)}">${esc(a.state)}</td><td class="wrap muted">${esc(a.reached_text || "-")}</td><td>${a.fixing ? esc(a.fixing) : `<span class="muted">-</span>`}</td>` +
    `<td class="n">${a.page ? a.page.cuts.length : 0}</td></tr>`;
  const apps = secHead("", "Apps", p.apps.length) + `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">app</th><th>cut</th><th data-role="glance">state</th>` +
    `<th>reached</th><th>fixing</th><th class="n">cuts</th></tr>${p.apps.map(app).join("")}</table></div>`;
  // Each app's cut as its release page draws it: the pipeline, then every cut of the version.
  const pipes = p.apps.filter((a) => a.page).map((a) => secHead("", `${a.app} ${a.tag}`, undefined, a.level) + relPipeline(a.page, "h3")).join("");
  return head(`<b>${esc(p.version)}</b> <span class="${levelClass(p.level)}">${esc(p.status)}</span>`) + down + facts + table + apps + pipes;
}
// A day's bar colour: no results grey, no failure green, under 1% failed amber, more red.
function dayColor(d) {
  if (!d.ok && !d.fail) return APP_DAY_COLOR.none;
  if (!d.fail) return APP_DAY_COLOR.up;
  return d.fail / (d.ok + d.fail) < 0.01 ? APP_DAY_COLOR.dip : APP_DAY_COLOR.down;
}
const dayLabel = (t) => new Date(t * 1e3).toLocaleDateString([], { month: "short", day: "numeric" });
// Every bar the same height, its colour the day's word; the tip says the day and its uptime.
const dayBars = (days) => `<div class="appdays">${columns(days.map((d) => ({
  key: "d" + d.at, label: "", segs: [{ v: 1, color: dayColor(d) }],
  tip: `${dayLabel(d.at)}: ${d.text}${d.fail ? `, ${d.fail} failed of ${d.ok + d.fail}` : ""}`,
})), { height: 34, yfmt: () => "" })}<div class="appdx muted"><span class="appd90">${days.length} days ago</span><span class="appd30">30 days ago</span><span>today</span></div></div>`;
// The last 24 whole hours' response time, one column an hour ending with the one before this, each
// that hour's average result, keyed by its start (hub_core::app_status); an hour with none is empty.
const LATENCY_HOURS = 24;
function latencyBars(pts, now) {
  if (!pts.length) return `<div class="muted">No response times in 24 hours.</div>`;
  const last = Math.floor(now / 3600) * 3600 - 3600, hours = new Map();
  for (const [t, ms] of pts) hours.set(Math.floor(t / 3600) * 3600, ms);
  const cols = Array.from({ length: LATENCY_HOURS }, (_, i) => {
    const h = last - (LATENCY_HOURS - 1 - i) * 3600, ms = hours.get(h);
    return { key: "h" + h, label: i % 6 === 0 ? clock(h * 1e3) : "", segs: [{ v: ms || 0, color: "var(--c1)" }],
      tip: `${clock(h * 1e3)}: ${ms === undefined ? "no result" : `average ${Math.round(ms)} ms`}` };
  });
  return columns(cols, { height: 70, yfmt: (v) => `${Math.round(v)} ms` });
}
function appCheck(c, now) {
  const up = c.uptime.map(([w, v]) => `<span class="appup"><span class="muted">${esc(w)}</span> ${esc(v)}</span>`).join("");
  return `<div class="panel appchk"><div class="bhead"><span><b>${esc(c.name)}</b> <span class="muted">${esc(c.group)}</span></span>` +
    `<span class="chip sm" style="--c:${LEVEL_COLOR[c.level] || APP_DAY_COLOR.none}">${esc(c.state.toUpperCase())}</span></div>` +
    `<div class="cline appups">${up}<span class="appup"><span class="muted">latency</span> ${esc(c.latency_text)}</span></div>` +
    dayBars(c.days) + `<div class="cline muted">Response time, hourly average, 24 hours</div>` + latencyBars(c.latency, now) + `</div>`;
}
const LEVEL_COLOR = { ok: "var(--idle)", warn: "var(--busy)", bad: "var(--wait)" };
function appIncidents(list) {
  if (!list.length) return `<div class="panel muted">No incidents in 7 days.</div>`;
  return `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">check</th><th data-role="glance">from</th><th data-role="glance">to</th><th>failed</th></tr>` +
    list.map((i) => `<tr><td>${esc(i.check)}</td><td>${stamp(i.from)}</td><td${i.to ? "" : ' class="bad"'}>${i.to ? stamp(i.to) : "ongoing"}</td><td>${esc(i.fails)}</td></tr>`).join("") +
    `</table></div>`;
}
// The open app's status section: what its Gatus checks say, each check's card, then its incidents.
function appStatus() {
  const d = apst.data;
  if (!d) return secHead("", "Status") + `<div class="${apst.err ? "panel down" : "empty"}">${apst.err ? esc(apst.err) : "reading..."}</div>`;
  const checked = d.newest ? `checked ${clock(d.newest * 1e3)} (${ago(d.newest)} ago)` : "no result yet";
  let h = secHead("", "Status") +
    `<div class="panel"><div class="appbanner"><span class="chip" style="--c:${LEVEL_COLOR[d.level]}">${esc(d.banner)}</span> <span class="muted">${esc(checked)}</span>` +
    (d.monitor ? ` <a href="${esc(d.monitor)}" target="_blank" rel="noopener">Gatus</a>` : "") + `</div>` +
    d.context.map(pagePart).join("") + pageRow("Read", clock(d.at * 1e3)) + `</div>`;
  const errs = apst.err ? [`refresh failed, showing the last read: ${apst.err}`, ...d.errors] : d.errors;
  if (errs.length) h += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  h += secHead("", "Checks", d.checks.length || null);
  if (d.checks.length && d.unchecked.length) h += `<div class="cline muted">No Gatus check yet: ${esc(d.unchecked.join(", "))}</div>`;
  h += d.checks.length ? d.checks.map((c) => appCheck(c, d.at)).join("") : `<div class="panel muted">No check reports for ${esc(d.groups.join(" or "))} yet.</div>`;
  return h + secHead("", "Incidents", d.incidents.length || null) + appIncidents(d.incidents);
}
$("releases").addEventListener("toggle", (e) => { if (e.target.dataset?.k) REL_OPEN[e.target.dataset.k] = e.target.open; }, true);

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  const win = t.closest("[data-flow-win]");
  if (win) { relFlow.window = win.dataset.flowWin; relFlow.from = relFlow.to = ""; relFlowRefresh(); return; }
  if (t.closest("a") || t.closest("button") || t.closest("summary") || t.closest("select") || t.closest("tr.rcd")) return;
  const rh = t.closest("tr.rh");
  if (rh) { loadChangelog(rh.dataset.project, rh.dataset.tag); return; }
  const ch = t.closest("tr.rc");
  if (ch) { relCh = relCh === ch.dataset.ch ? null : ch.dataset.ch; relst.render(); return; }
  const tr = t.closest("tr.jr");
  if (!tr) return;
  // An in-app link: Back returns to the table as it was.
  const view = st.views.releases;
  relCh = null;
  location.hash = `#releases/apps/${encodeURIComponent(tr.dataset.key)}${view ? "?" + view : ""}`;
});

$("releases").addEventListener("change", (e) => {
  const pick = e.target.closest("select.rel-tag");
  if (pick) loadChangelog(pick.dataset.project, pick.value);
  const flow = e.target.closest("select.rel-flow");
  if (flow) { relFlow.project = flow.value; relFlowRefresh(); }
  // Either day picked draws from that day to the other, or that one day; both cleared is the default.
  const from = e.target.closest("[data-flow-from]"), to = e.target.closest("[data-flow-to]");
  if (from || to) {
    if (from) relFlow.from = from.value;
    if (to) relFlow.to = to.value;
    const [a, b] = [relFlow.from, relFlow.to];
    relFlow.window = a || b ? `${a || b}..${b || a}` : "";
    relFlowRefresh();
  }
});

// A ledger write also refreshes the apps: their Builds and the RELEASED cell's `building`.
const relFeed = pushed("releases", ["releases", "builds"], relst.refresh);
const relRunsFeed = pushed("releases", ["builds"], relRuns.refresh);
// Flow re-reads on a ledger write or a new snapshot only while it shows; one that came while it
// did not is read the next time it opens.
const relFlowFeed = pushed("releases", ["releases", "builds"], relFlowRefresh, relFlowOn);
const ageReleases = poll("releases", () => relst.render(), RELEASES_AGE_MS);
TABS.releases = {
  // Always read: a link from a Projects card arrives here with a new view in the URL.
  show() {
    const page = relDetail() ? st.page : "";
    if (page !== apst.page) Object.assign(apst, { page, data: null, err: null });
    if (page !== rlst.page) { Object.assign(rlst, { page, data: null, err: null }); if (relVer()) refreshRelease(); }
    if (page !== vrst.page) { Object.assign(vrst, { page, data: null, err: null }); if (relVersion()) refreshVersion(); }
    relFeed.show(true); relRunsFeed.show(true); ageReleases(); pollAppPage();
    if (relFlowOn()) relFlowFeed.show(!relFlow.data);
  },
  inner(id) { if (id === "flow") relFlowFeed.show(!relFlow.data); },
  onEvent(ev) { relFeed.onEvent(ev); relRunsFeed.onEvent(ev); relFlowFeed.onEvent(ev); },
};
