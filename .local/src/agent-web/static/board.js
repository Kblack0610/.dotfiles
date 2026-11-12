"use strict";
// The Board tab (every project's rows) and the rows under an opened project on Projects: the
// shared table (table.js) over the rows from `notes board --json` (/api/board, which filters and
// sorts by the view in the showing tab's URL query): the human sheet, the agent board, playtest,
// open ones under their sheet sections (each row's `label`) then the closed ones, each row's
// `when` its queue state and forecast or its close day and PRs, the hub's words for both; each
// profile's Focus is a count linking to the Daily tab. A closed row has no actions. A row opens under itself
// with its actions: add, start, done, drop, move (to a project or a version), a release sooner
// or later, edit and tags go through `notes ptask --exact` with the row's raw line (POST
// /api/board), so a row changed elsewhere since this page read it fails the write, and the page
// says so and re-reads. Nothing watches the notes vault, so the tab reads when shown, after each
// write, on resync, and on Refresh.

const B_LANES = ["human", "agent", "playtest"];
const B_PRIORITIES = ["urgent", "high", "low"];
// The Board holds thousands of rows, so the table stops here until asked.
const B_OPEN = 200;
// One view serves both tabs, so what it reads and where its query lives follow the showing tab.
const bOnBoard = () => st.tab === "board";
const bTab = () => (bOnBoard() ? "board" : "projects");
const bScope = () => (bOnBoard() ? "all" : pst.open);
// The table is drawn under the add form (renderBoard), which a re-read leaves alone.
const bst = tblTab({
  get tab() { return bTab(); }, get scroller() { return bTab(); },
  id: "board", el: "b-tbl", on: "b-root", refresh: () => refreshBoard(), table: (t) => t.feed?.table,
  shown: () => bOnBoard() || (st.tab === "projects" && !!pst.open), hint: "search, or lane:agent priority:high size:s -tag:ai",
  state: {
    feed: null, busy: false, msg: "",
    draft: { key: "", lane: "human", priority: "high", to: "", game: "", text: "" },
    // `sel` is the opened row (bSel); `form` the one row whose done, drop, move, edit or tags form
    // is open: { k, kind }.
    form: null, all: false, controlsKey: "",
  },
  body: () => bBody(),
});

// The view moves to the tab that shows it; rows read for the other scope go with the move.
function bMount(parent) {
  $(parent).appendChild($("b-root"));
  if (bst.scope === bScope()) return;
  bst.feed = null; bst.err = null; bst.msg = ""; bst.sel = null; bst.form = null; bst.all = false; bst.controlsKey = "";
}

// `feed.rows` is what the view keeps; a row's action index is into that list, which the drawn
// table always comes from. An answer for a scope no longer showing is dropped, and whatever
// opened the new one reads it. The Projects list has no rows to read.
const refreshBoard = coalesce(async () => {
  const scope = bScope();
  if (!scope) return;
  const p = tblParams(st.views[bTab()]);
  if (scope !== "all") p.set("scope", scope);
  const q = p.toString();
  try {
    const got = await api("/api/board" + (q ? "?" + q : ""));
    if (scope === bScope()) { bst.feed = got; bst.scope = scope; bst.err = null; }
  } catch (e) { if (scope === bScope()) bst.err = e.message; }
  if (st.tab === "projects") renderProjects();
  else if (bOnBoard()) renderBoard();
});

// A row's identity across re-reads: its sheet and its exact line.
const bKey = (r) => r.sheet + "\n" + r.raw;
// An opened row with an id stays open through a write that rewrites its line; one with no id
// closes, its line being all that names it.
const bSel = (r) => r.sheet + "\n" + (r.id || r.raw);
const bProjKey = (p) => p.profile + "/" + p.project;
const bOpt = (list, cur, label) => list.map((v) => {
  const [val, text] = Array.isArray(v) ? v : [v, v];
  return `<option value="${esc(val)}"${val === cur ? " selected" : ""}>${esc(label ? label(text) : text)}</option>`;
}).join("");

function bControls() {
  const d = bst.draft, keys = bst.feed.projects.map(bProjKey);
  const playtest = d.lane === "playtest";
  return `<div class="card qadd badd">` +
    `<input id="b-text" placeholder="New row, one line (Enter to add)" value="${esc(d.text)}">` +
    `<div class="opts">` +
    `<select id="b-proj"><option value="">project...</option>${bOpt(keys, d.key)}</select>` +
    `<select id="b-lane">${bOpt(B_LANES, d.lane)}</select>` +
    `<select id="b-prio">${bOpt(B_PRIORITIES, d.priority)}</select>` +
    (playtest
      ? `<input id="b-game" placeholder="game (optional)" value="${esc(d.game)}">`
      : `<input id="b-to" placeholder="version vX.Y.Z (optional)" value="${esc(d.to)}">`) +
    `<button class="btn primary" id="b-add"${bst.busy ? " disabled" : ""}>${bst.busy ? "Adding..." : "Add"}</button>` +
    `</div><div class="err" id="b-msg">${esc(bst.msg)}</div></div>`;
}

// The opened row, under its line in the table: its whole text and tags, then its actions.
function bRow(r, i) {
  const k = bKey(r);
  const tags = [r.version, r.tier && "tier " + r.tier, r.worker && "worker " + r.worker,
    r.size && "size " + r.size, r.game, r.ask && "#ask", ...(r.tags || []).map((t) => "#" + t)]
    .filter(Boolean).map((t) => `<span class="qtag">${esc(t)}</span>`).join("");
  const meta = [
    `<span class="qprio ${esc(r.priority)}">${esc(r.priority)}</span>`,
    esc(r.lane), r.state === "doing" ? "<b>in progress</b>" : "",
    r.since ? "since " + esc(r.since) : "", r.id ? `<code>${esc(r.id)}</code>` : "",
    r.epic || r.parent ? "epic " + bEpic(r, i) : "",
  ].filter(Boolean).join(", ");
  let acts = "";
  if (r.state === "done") {
    // Closed rows are the record: reopening one is the sheet's.
  } else if (bst.form && bst.form.k === k) {
    const cancel = `<button class="btn sm" data-formcancel="${i}">Cancel</button></div>`;
    const kind = bst.form.kind;
    if (kind === "done" || kind === "drop") {
      // Every close says how: done with a proof or why it has none, or dropped with why or the
      // id of the row it duplicates. A dropped row stays on the sheet, ticked, with its reason.
      const done = kind === "done";
      const kinds = CLOSE_HOW[kind];
      acts = `<div class="opts">` +
        `<select data-formkind="${i}">${bOpt(kinds, kinds[0][0])}</select>` +
        `<input data-forminput="${i}" placeholder="${done ? "pr:123, a URL, or why it is unverified" : "stale, superseded, moved: ideas.md, or ar-142"}">` +
        `<button class="btn sm primary" data-formgo="${i}">${done ? "Mark done" : "Drop"}</button>` + cancel;
    } else if (kind === "move") {
      const names = [...new Set(bst.feed.projects.map((p) => p.project))].filter((p) => p !== r.project).sort();
      acts = `<div class="opts">` +
        `<select data-movedest="${i}"><option value="">this project</option>${bOpt(names, "")}</select>` +
        `<input data-forminput="${i}" placeholder="version vX.Y.Z (optional with a project)">` +
        `<button class="btn sm primary" data-formgo="${i}">Move</button>` + cancel;
    } else if (kind === "tag") {
      // A row has one size, so adding size/m replaces its old one; a release is Move's.
      acts = `<div class="opts">` +
        `<input data-forminput="${i}" placeholder="add: size/s requested">` +
        `<input data-formremove="${i}" placeholder="remove: ai">` +
        `<button class="btn sm primary" data-formgo="${i}">Save tags</button>` + cancel;
    } else {
      acts = `<div class="opts">` +
        `<input data-forminput="${i}" value="${esc(r.text)}">` +
        `<button class="btn sm primary" data-formgo="${i}">Save</button>` + cancel;
    }
  } else {
    // A playtest check has no version and no edit: notes takes add, done and drop there.
    const versioned = r.lane !== "playtest";
    acts = `<div class="opts">` +
      (versioned && r.state === "open" ? `<button class="btn sm" data-start="${i}">Start</button>` : "") +
      `<button class="btn sm" data-done="${i}">Done...</button>` +
      (versioned ? `<button class="btn sm" data-promote="${i}" title="one release sooner">Sooner</button>` +
        `<button class="btn sm" data-demote="${i}" title="one release later">Later</button>` +
        `<button class="btn sm" data-move="${i}">Move...</button>` +
        `<button class="btn sm" data-edit="${i}">Edit...</button>` +
        `<button class="btn sm" data-tag="${i}">Tags...</button>` : "") +
      `<button class="btn sm" data-drop="${i}">Drop...</button></div>`;
  }
  return `<div class="card qitem brow"><div class="meta">${meta} ${tags}</div>` +
    `<div class="q">${esc(r.text)}</div>${acts}</div>`;
}

// What a row is leads, then the epic it serves, then what to do about it. Version, size, tier,
// since and the whole line are the opened row's (bRow), so the table fits the screen.
const B_COLS = { section: ["section"], title: ["title"], epic: ["epic"], priority: ["priority"], state: ["state"], when: ["when"], project: ["project"], lane: ["lane"], id: ["id"] };
const B_SPAN = Object.keys(B_COLS).length;
const bDash = (v) => esc(v == null || v === "" ? "-" : v);
// The row's epic as a link to that row, its parent's id when that row is not on the board,
// or "" when it is under none.
const bEpic = (r, i) => r.epic || r.parent ? tblLink(tblLinks(bst.feed.table, i).epic, r.epic || r.parent) : "";

// One line of the table, and the opened record under it. The title cell holds the row's area,
// its title and what the title leaves out (hub_core::tasks::title_and_rest); the epic cell opens
// the epic. The opened row has the whole line.
function bLine(r, i) {
  const open = bSel(r) === bst.sel;
  const area = r.area ? `<span class="qtag">${esc(r.area)}</span> ` : "";
  const sum = r.summary ? `<div class="bsum clamp muted">${esc(r.summary)}</div>` : "";
  // An epic is the deliverable itself; any other row under none says so, for triage.
  const epic = bEpic(r, i) || (r.section === "epics" ? "" : `<span class="muted">no epic</span>`);
  const line = `<tr class="jr${open ? " sel" : ""}" data-row="${i}">` +
    `<td><b>${esc(r.label || "")}</b></td>` +
    `<td class="btitle"><div class="bt">${area}${esc(r.title)}</div>${sum}</td>` +
    `<td class="bepic">${epic}</td>` +
    `<td><span class="qprio ${esc(r.priority)}">${esc(r.priority)}</span></td>` +
    `<td>${r.state === "doing" ? "<b>doing</b>" : esc(r.state)}</td><td class="bwhen">${bDash(r.when)}</td>` +
    `<td>${bDash(r.project)}</td><td>${esc(r.lane)}</td><td><code>${bDash(r.id)}</code></td></tr>`;
  return open ? line + `<tr class="bopen"><td colspan="${B_SPAN}">${bRow(r, i)}</td></tr>` : line;
}

function bBody() {
  const t = bst.feed.table, shown = bst.feed.rows, one = bScope() !== "all";
  const rows = bst.all ? shown : shown.slice(0, B_OPEN);
  const more = shown.length - rows.length;
  // Lines still in an inbox are rows the triager has not filed: the Filed today chip is the ones it has.
  const waiting = bst.feed.projects.filter((p) => !one || bProjKey(p) === bScope()).reduce((s, p) => s + (p.inbox || 0), 0);
  // Focus rows are the Daily tab's (hub_core::tasks counts them): All says how many and links there.
  const focus = one ? [] : bst.feed.focus || [];
  const fbadge = focus.length ? `<a class="btn sm" href="#daily">Daily: ${focus.map((c) => `${esc(c.profile)} ${c.open}`).join(", ")} open</a>` : "";
  return `<div class="muted qstats">${t.shown} of ${t.total} rows${waiting ? `, ${waiting} still waiting in the inboxes` : ""} ${fbadge}` +
    ` <button class="btn sm" id="b-refresh">Refresh</button></div>` +
    (bst.err ? `<div class="panel down">${esc(bst.err)}</div>` : "") +
    (bst.feed.errors || []).map((e) => `<div class="panel down">no forecast or queue state: ${esc(e)}</div>`).join("") +
    (shown.length
      ? `<div class="panel scroll"><table class="tbl">${tblHead(t, B_COLS)}${rows.map(bLine).join("")}</table>` +
        tblMore(more, "more") + `</div>`
      : `<div class="card muted">${t.total ? "No row matches." : "No rows."}</div>`);
}

function renderBoard() {
  const el = $("b-root");
  if (!bst.feed) { el.innerHTML = `<div class="empty">${bst.err ? esc(bst.err) : "Loading..."}</div>`; return; }
  // The add form is drawn once per project list, so a re-read never eats what is being typed.
  const key = bst.feed.projects.map(bProjKey).join(",");
  if (key !== bst.controlsKey || !$("b-tbl")) {
    bst.controlsKey = key;
    el.innerHTML = bControls() + `<div id="b-tbl"></div>`;
  } else {
    $("b-msg").textContent = bst.msg;
    $("b-add").disabled = bst.busy;
    $("b-add").textContent = bst.busy ? "Adding..." : "Add";
  }
  bst.render();
}

function bSaveDraft() {
  if (!$("b-text")) return;
  const d = bst.draft;
  d.text = $("b-text").value; d.key = $("b-proj").value; d.priority = $("b-prio").value;
  if ($("b-to")) d.to = $("b-to").value;
  if ($("b-game")) d.game = $("b-game").value;
  const lane = $("b-lane").value;
  if (lane !== d.lane) { d.lane = lane; bst.controlsKey = ""; renderBoard(); }
}

// One write; the reply is notes' own line, and any failure (a stale row most often) is shown
// as notes said it, then the board is read again.
async function bWrite(body, okMsg) {
  try {
    const r = await post("/api/board", body);
    bst.msg = okMsg || (r && r.out) || "";
    return true;
  } catch (e) {
    bst.msg = e.message;
    return false;
  } finally {
    renderBoard();
    refreshBoard();
    refreshProjects();
  }
}

async function bAdd() {
  bSaveDraft();
  const d = bst.draft;
  if (!d.key) { bst.msg = "Pick a project."; renderBoard(); return; }
  if (!d.text.trim()) { bst.msg = "Type the row."; renderBoard(); return; }
  const [profile, project] = d.key.split("/");
  bst.busy = true; bst.msg = ""; renderBoard();
  const body = { verb: "add", profile, project, lane: d.lane, text: d.text.trim(), priority: d.priority };
  if (d.lane === "playtest") body.game = d.game.trim(); else body.to = d.to.trim();
  const ok = await bWrite(body, `Added to ${d.key} (${d.lane}).`);
  bst.busy = false;
  if (ok) { d.text = ""; if ($("b-text")) $("b-text").value = ""; }
  renderBoard();
}

$("b-root").addEventListener("click", (e) => {
  const t = e.target, rows = bst.feed ? bst.feed.rows : [];
  if (t.id === "b-add") { bAdd(); return; }
  if (t.id === "b-refresh") { bst.msg = ""; refreshBoard(); return; }
  const d = t.dataset;
  const r = rows[d.start || d.done || d.drop || d.promote || d.demote || d.move || d.edit || d.tag || d.formgo || d.formcancel];
  if (!r) {
    if (t.closest("a")) return;
    const line = t.closest("tr[data-row]");
    if (!line) return;
    const k = bSel(rows[line.dataset.row]);
    bst.sel = bst.sel === k ? null : k;
    bst.form = null;
    bst.render();
    return;
  }
  const k = bKey(r);
  if (d.start) { bWrite(Object.assign({ verb: "start" }, rowTarget(r)), "Queued: it starts when you are away."); return; }
  if (d.promote || d.demote) {
    const verb = d.promote ? "promote" : "demote";
    bWrite(Object.assign({ verb }, rowTarget(r)), d.promote ? "One release sooner." : "One release later.");
    return;
  }
  const opened = d.done || d.drop || d.move || d.edit || d.tag;
  if (opened) {
    bst.form = { k, kind: d.done ? "done" : d.drop ? "drop" : d.move ? "move" : d.tag ? "tag" : "edit" };
    bst.render();
    const i = $("b-root").querySelector(`[data-forminput="${opened}"]`);
    if (i) i.focus();
    return;
  }
  if (d.formcancel) { bst.form = null; bst.render(); return; }
  if (d.formgo && bst.form) {
    const i = d.formgo, q = (a) => $("b-root").querySelector(`[data-${a}="${i}"]`);
    const v = q("forminput").value.trim(), kind = bst.form.kind;
    let body, ok;
    if (kind === "done" || kind === "drop") {
      const how = q("formkind").value;
      if (!v) { bst.msg = CLOSE_NEED[how]; renderBoard(); return; }
      body = { verb: kind, [how]: v }; ok = kind === "done" ? "Done." : "Dropped.";
    } else if (kind === "move") {
      const dest = q("movedest").value;
      if (!dest && !v) { bst.msg = "Pick a project, a version, or both."; renderBoard(); return; }
      body = { verb: "move", dest, to: v }; ok = dest ? `Moved to ${dest}.` : `Moved to ${v}.`;
    } else if (kind === "tag") {
      const rm = q("formremove").value.trim();
      if (!v && !rm) { bst.msg = "Type a tag to add or remove."; renderBoard(); return; }
      body = { verb: "tag", add: v, remove: rm }; ok = "Tags saved.";
    } else {
      if (!v) { bst.msg = "Type the new text."; renderBoard(); return; }
      body = { verb: "edit", text: v }; ok = "Edited.";
    }
    bst.form = null;
    bWrite(Object.assign(body, rowTarget(r)), ok);
  }
});
for (const ev of ["input", "change"]) $("b-root").addEventListener(ev, (e) => { if (e.target.closest(".badd")) bSaveDraft(); });
$("b-root").addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  if (e.target.id === "b-text") { e.preventDefault(); bAdd(); return; }
  const i = e.target.dataset.forminput || e.target.dataset.formremove;
  if (i != null) { e.preventDefault(); const b = $("b-root").querySelector(`[data-formgo="${i}"]`); if (b) b.click(); }
});

TABS.board = {
  show() { bMount("board"); renderBoard(); refreshBoard(); },
  onEvent(ev) { if (st.tab === "board" && ev.kind === "resync") refreshBoard(); },
};
