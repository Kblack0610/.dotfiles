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

const REL_COLS = { project: ["project"], channel: ["channel"], pinned: ["pinned", "opt"], live: ["live"], status: ["status"], telemetry: ["telemetry", "opt"], deps: ["deps", "opt"] };

function releaseRow(r) {
  const open = relKey(r) === relst.sel;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(relKey(r))}">` +
    `<td>${esc(r.project)}</td><td class="wrap">${esc(r.label)}</td><td class="opt">${esc(r.pinned_text)}</td>` +
    `<td class="${r.status === "drift" ? "bad" : ""}">${esc(r.live_text)}</td><td class="${relClass(r.status_level)}">${esc(r.status)}</td>` +
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

function releaseDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const status = [r.drift_since ? `drift since ${when(r.drift_since)}` : "", r.probed_at ? `probed ${when(r.probed_at)}` : ""].filter(Boolean).join(", ");
  return `<tr class="wdet"><td colspan="7"><div class="sdet"><div class="muted">${status || esc(r.status)}</div>` +
    line("Pinned", releaseSide(r.pinned, r.pinned_text)) + line("Live", releaseSide(r.live, r.live_text)) +
    line("Tag", esc(r.tag || "")) + line("Where", esc(r.where || "")) +
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

// The Builds section's slot under the channels: it reads ~/.local/state/ci/runs.jsonl with its
// own reader (ar-956), and until then it draws nothing, so the tab claims no build state.
function releaseBuilds() { return ""; }

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.jr");
  if (!tr) return;
  relst.sel = relst.sel === tr.dataset.key ? null : tr.dataset.key;
  relst.render();
});

const relFeed = pushed("releases", ["releases"], relst.refresh);
const ageReleases = poll("releases", () => relst.render(), RELEASES_AGE_MS);
TABS.releases = {
  // Always read: a link from a Projects card arrives here with a new view in the URL.
  show() { relFeed.show(true); ageReleases(); },
  onEvent: relFeed.onEvent,
};
