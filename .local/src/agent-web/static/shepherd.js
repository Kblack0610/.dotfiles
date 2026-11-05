"use strict";
// Sessions' shepherd half (the Shepherd tab until phase 3 of the hub layout). The pass from
// `fleet-shepherd stats` is the first line of the Sessions list; the overview folds the full
// pass, what Binks owes (each line the last `fleet-shepherd check` handed to a pass: its role, how
// long it has been due, and whether the last pass left it unhandled) and every rundown and chat
// answer the shepherd kept (`fleet-shepherd log --rundown`, one file each in
// ~/.agent/shepherd/rundowns). The chat is the shepherd's own session, pinned first in the list:
// opening it shows its transcript and a box that types into its pane, so an answer it gives there
// is also kept as a rundown. The lines a pass skipped on purpose, with why, are the shepherd's
// skips in the Actions tab.

const shst = { data: null, err: null, open: new Set() };

const refreshShepherd = coalesce(async () => {
  try { shst.data = await api("/api/shepherd"); shst.err = null; } catch (e) { shst.err = e.message; }
  if (shst.data && shst.data.rundowns.length && !shst.open.size) shst.open.add(shst.data.rundowns[0].file);
  if (st.tab === "sessions") { renderList(); renderOverview(); }
});

// A stamp as the reader's local time; the file keeps UTC.
function shepWhen(stamp) {
  const d = new Date(stamp.replace(" UTC", "Z").replace(" ", "T"));
  return isNaN(d) ? esc(stamp) : esc(d.toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }));
}

function rundownCard(r) {
  const open = shst.open.has(r.file) ? " open" : "";
  return `<details class="card rd"${open} data-file="${esc(r.file)}"><summary><b>${esc(r.title)}</b>` +
    ` <span class="muted">${shepWhen(r.stamp)}</span></summary><div class="rd-body md">${md(r.body)}</div></details>`;
}

// Minutes since an epoch in seconds, as "12m"; "-" when the ledger does not say.
const shepAge = (t) => (t ? dur((Date.now() / 1e3 - t) / 60) : "-");

function dueRow(d) {
  const flag = d.unhandled ? `<span class="pill ask">unhandled</span>` : "";
  return `<div class="card"><div class="pills">${flag}<span class="pill">${esc(d.role || "?")}</span>` +
    `<span class="pill">due ${shepAge(d.first_seen)}</span></div><div class="rd-body">${esc(d.line)}</div></div>`;
}

// The pass card: what `fleet-shepherd stats` says, the numbers the Queue chip and Home Assistant show.
function passHtml(s) {
  if (!s) return `<div class="empty">fleet-shepherd stats gave nothing.</div>`;
  const id = (x) => esc((x || "").slice(0, 8));
  const pills = [];
  if (s.stuck) pills.push(`<span class="pill ask">stuck</span>`);
  if (s.unhandled) pills.push(`<span class="pill ask">${s.unhandled} unhandled, ${s.unhandled_checks} checks in a row</span>`);
  const now = s.pass_running
    ? `pass ${id(s.pass_id)} ${esc(s.pass_status)}, ${dur(s.pass_age_s / 60)}: <code>${esc(s.attach)}</code>`
    : s.pass_id ? `no pass running; the last was ${id(s.pass_id)} (${esc(s.pass_status)}): <code>${esc(s.attach)}</code>` : "no pass on record";
  const last = s.last_pass_id ? `last verdict ${esc(s.last_verdict || "?")} for pass ${id(s.last_pass_id)}, ${dur(s.last_pass_age_s / 60)} ago` : "no verdict on record";
  const why = s.stuck_why ? `<div class="rd-body">${esc(s.stuck_why)}</div>` : "";
  return `<div class="card">` +
    (pills.length ? `<div class="pills">${pills.join("")}</div>` : "") + why +
    `<div class="rd-body">${now}</div><div class="rd-body">${last}</div>` +
    `<div class="rd-body muted">last 24h: ${s.passes_24h} passes, ${s.nudges_24h} nudges, ${s.escalations_24h} escalations, ${s.skips_24h} skips; ` +
    `${s.due} due, ${s.skipped} skipped, ${s.paged} paged</div></div>`;
}

function dueHtml(l) {
  const pass = l.lease_at ? `last pass ${shepAge(l.lease_at)} ago (${esc(l.lease_holder)})` : "no pass yet";
  const owed = l.due.length ? l.due.map(dueRow).join("")
    : `<div class="empty">Nothing due: the last check found nothing to move.</div>`;
  const skips = `<div class="row-end"><button class="btn" data-skips>Skipped on purpose, in Actions</button></div>`;
  return `<h3 class="sub">Due <span class="muted">${l.due.length}, ${pass}</span></h3>${owed}${skips}`;
}

// The pass in one line, the first row of the Sessions list.
function passLine() {
  const d = shst.data, x = d && d.stats;
  if (shst.err) return `shepherd: ${esc(shst.err)}`;
  if (!x) return d ? "shepherd: stats gave nothing" : "shepherd: reading";
  const run = x.pass_running ? `pass ${dur(x.pass_age_s / 60)} ${esc(x.pass_status)}` : `no pass running, last verdict ${esc(x.last_verdict || "?")}`;
  const due = d.ledger ? `, ${d.ledger.due.length} due` : "";
  const bad = (x.stuck ? ", <b class=\"ci fail\">stuck</b>" : "") + (x.unhandled ? `, <b class="ci fail">${x.unhandled} unhandled</b>` : "");
  return `shepherd: ${run}${due}${bad}`;
}

// The overview's shepherd sections: the pass and what is due, then the kept rundowns.
function shepherdOverview() {
  const d = shst.data;
  const list = d ? d.rundowns : [];
  const chat = d && d.target ? `<button class="btn" data-chat>Chat: open ${esc(d.target)} (${esc(d.status)})</button>`
    : '<span class="muted">No shepherd armed. Its lease is set when fleet-shepherd starts a pass.</span>';
  const pass = shst.err ? `<div class="card err">${esc(shst.err)}</div>` : !d ? '<div class="empty">Loading.</div>'
    : passHtml(d.stats) + dueHtml(d.ledger);
  const rds = shst.err ? "" : !d ? '<div class="empty">Loading.</div>'
    : list.length ? list.map(rundownCard).join("")
    : '<div class="empty">No rundowns kept yet. The shepherd writes one with <code>fleet-shepherd log --rundown</code> each time it sums up the fleet or answers you in its session.</div>';
  return fold("shep", "Shepherd", `<div class="ovbar">${chat}</div>${pass}`) +
    fold("rundowns", `Rundowns <span class="muted">${list.length ? `${list.length} newest` : ""}</span>`, rds);
}

$("scroll").addEventListener("click", (e) => {
  if (st.sel) return;
  if (e.target.dataset.skips !== undefined) showActions("shepherd", "skip");
  else if (e.target.dataset.chat !== undefined) {
    const a = shst.data && st.agents.find((x) => x.target === shst.data.target);
    if (a) select(a);
  }
});
// Remember which rundowns are open, so a re-render after a new one keeps the reader's place.
$("scroll").addEventListener("toggle", (e) => {
  const f = e.target.dataset && e.target.dataset.file;
  if (f) { if (e.target.open) shst.open.add(f); else shst.open.delete(f); }
}, true);
