"use strict";
// The Board tab: every project's open rows from `notes board --json` (/api/board): the human
// sheet, the agent board, playtest, and each profile's Focus (read-only here). Add, start, done,
// remove, move (to a project or a wave), a wave sooner or later, and edit go through
// `notes ptask --exact` with the row's raw line (POST /api/board), so a
// row changed elsewhere since this page read it fails the write, and the page says so and
// re-reads. Nothing watches the notes vault, so the tab reads when shown, after each write, on
// resync, and on Refresh.

const B_LANES = ["human", "agent", "playtest"];
const B_PRIORITIES = ["urgent", "high", "low"];
const bst = {
  feed: null, err: null, busy: false, msg: "",
  filter: { profile: "", project: "", lane: "", priority: "", q: "" },
  draft: { key: "", lane: "human", priority: "high", to: "", game: "", text: "" },
  // `form` is the one row whose done, drop, move or edit form is open: { k, kind }.
  open: {}, form: null, controlsKey: "",
};

const refreshBoard = coalesce(async () => {
  try { bst.feed = await api("/api/board"); bst.err = null; } catch (e) { bst.err = e.message; }
  if (st.tab === "board") renderBoard();
});

// A row's identity across re-reads: its sheet and its exact line.
const bKey = (r) => r.sheet + "\n" + r.raw;
const bProjKey = (p) => p.profile + "/" + p.project;
const bOpt = (list, cur, label) => list.map((v) => {
  const [val, text] = Array.isArray(v) ? v : [v, v];
  return `<option value="${esc(val)}"${val === cur ? " selected" : ""}>${esc(label ? label(text) : text)}</option>`;
}).join("");

function bControls() {
  const f = bst.filter, d = bst.draft, projects = bst.feed.projects;
  const profiles = [...new Set(projects.map((p) => p.profile))].sort();
  const keys = projects.map(bProjKey);
  const playtest = d.lane === "playtest";
  return `<div class="card qadd badd">` +
    `<input id="b-text" placeholder="New row, one line (Enter to add)" value="${esc(d.text)}">` +
    `<div class="opts">` +
    `<select id="b-proj"><option value="">project...</option>${bOpt(keys, d.key)}</select>` +
    `<select id="b-lane">${bOpt(B_LANES, d.lane)}</select>` +
    `<select id="b-prio">${bOpt(B_PRIORITIES, d.priority)}</select>` +
    (playtest
      ? `<input id="b-game" placeholder="game (optional)" value="${esc(d.game)}">`
      : `<input id="b-to" placeholder="wave vX.Y.Z (optional)" value="${esc(d.to)}">`) +
    `<button class="btn primary" id="b-add"${bst.busy ? " disabled" : ""}>${bst.busy ? "Adding..." : "Add"}</button>` +
    `</div><div class="err" id="b-msg">${esc(bst.msg)}</div></div>` +
    `<div class="card bfilter"><div class="opts">` +
    `<input id="bf-q" placeholder="filter text, #tag" value="${esc(f.q)}">` +
    `<select id="bf-profile"><option value="">every profile</option>${bOpt(profiles, f.profile)}</select>` +
    `<select id="bf-project"><option value="">every project</option>${bOpt(keys, f.project)}</select>` +
    `<select id="bf-lane"><option value="">every lane</option>${bOpt([...B_LANES, "focus"], f.lane)}</select>` +
    `<select id="bf-priority"><option value="">any priority</option>${bOpt(B_PRIORITIES, f.priority)}</select>` +
    `<button class="btn sm" id="b-refresh">Refresh</button>` +
    `</div></div>`;
}

function bMatch(r) {
  const f = bst.filter;
  if (r.state === "done") return false;
  if (f.profile && r.profile !== f.profile) return false;
  if (f.project && (r.profile + "/" + r.project) !== f.project) return false;
  if (f.lane && r.lane !== f.lane) return false;
  if (f.priority && r.priority !== f.priority) return false;
  const q = f.q.trim().toLowerCase();
  return !q || r.raw.toLowerCase().includes(q);
}

function bRow(r, i) {
  const k = bKey(r);
  const focus = r.lane === "focus";
  const tags = [r.wave, r.target && "-> " + r.target, r.tier && "tier " + r.tier, r.worker && "worker " + r.worker,
    r.size && "size " + r.size, r.game, r.ask && "#ask", ...(r.tags || []).map((t) => "#" + t)]
    .filter(Boolean).map((t) => `<span class="qtag">${esc(t)}</span>`).join("");
  const meta = [
    `<span class="qprio ${esc(r.priority)}">${esc(r.priority)}</span>`,
    esc(r.lane), r.state === "doing" ? "<b>in progress</b>" : "",
    r.since ? "since " + esc(r.since) : "", r.id ? `<code>${esc(r.id)}</code>` : "",
  ].filter(Boolean).join(", ");
  let acts = "";
  if (focus) {
    acts = `<div class="muted">Focus is the human's day; edit it in the daily note.</div>`;
  } else if (bst.form && bst.form.k === k) {
    const cancel = `<button class="btn sm" data-formcancel="${i}">Cancel</button></div>`;
    const kind = bst.form.kind;
    if (kind === "done" || kind === "drop") {
      // Every close says how: done with a proof or why it has none, or dropped with why or the
      // id of the row it duplicates. A dropped row stays on the sheet, ticked, with its reason.
      const done = kind === "done";
      const kinds = done ? [["proof", "proof"], ["unverified", "unverified, because"]] : [["why", "why"], ["dup", "duplicate of id"]];
      acts = `<div class="opts">` +
        `<select data-formkind="${i}">${bOpt(kinds, kinds[0][0])}</select>` +
        `<input data-forminput="${i}" placeholder="${done ? "pr:123, a URL, or why it is unverified" : "stale, superseded, moved: ideas.md, or ar-142"}">` +
        `<button class="btn sm primary" data-formgo="${i}">${done ? "Mark done" : "Drop"}</button>` + cancel;
    } else if (kind === "move") {
      const names = [...new Set(bst.feed.projects.map((p) => p.project))].filter((p) => p !== r.project).sort();
      acts = `<div class="opts">` +
        `<select data-movedest="${i}"><option value="">this project</option>${bOpt(names, "")}</select>` +
        `<input data-forminput="${i}" placeholder="wave vX.Y.Z (optional with a project)">` +
        `<button class="btn sm primary" data-formgo="${i}">Move</button>` + cancel;
    } else {
      acts = `<div class="opts">` +
        `<input data-forminput="${i}" value="${esc(r.text)}">` +
        `<button class="btn sm primary" data-formgo="${i}">Save</button>` + cancel;
    }
  } else {
    // A playtest check has no waves and no edit: notes takes add, done and drop there.
    const waves = r.lane !== "playtest";
    acts = `<div class="opts">` +
      (waves && r.state === "open" ? `<button class="btn sm" data-start="${i}">Start</button>` : "") +
      `<button class="btn sm" data-done="${i}">Done...</button>` +
      (waves ? `<button class="btn sm" data-promote="${i}" title="one wave sooner">Sooner</button>` +
        `<button class="btn sm" data-demote="${i}" title="one wave later">Later</button>` +
        `<button class="btn sm" data-move="${i}">Move...</button>` +
        `<button class="btn sm" data-edit="${i}">Edit...</button>` : "") +
      `<button class="btn sm" data-drop="${i}">Drop...</button></div>`;
  }
  return `<div class="card qitem brow"><div class="meta">${meta} ${tags}</div>` +
    `<div class="q">${esc(r.text)}</div>${acts}</div>`;
}

function bGroups() {
  const rows = bst.feed.rows;
  const groups = new Map();
  rows.forEach((r, i) => {
    if (!bMatch(r)) return;
    const g = r.project ? r.profile + "/" + r.project : r.profile + " Focus";
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push([r, i]);
  });
  return groups;
}

function drawBoardList() {
  const el = $("b-list");
  if (!el) return;
  const groups = bGroups();
  const narrowed = bst.filter.project || bst.filter.q.trim();
  let n = 0, html = bst.err ? `<div class="panel down">${esc(bst.err)}</div>` : "";
  for (const [g, list] of [...groups].sort((a, b) => a[0].localeCompare(b[0]))) {
    n += list.length;
    const urgent = list.filter(([r]) => r.priority === "urgent").length;
    const open = bst.open[g] != null ? bst.open[g] : !!narrowed;
    html += `<details data-k="${esc(g)}"${open ? " open" : ""}><summary><h2 class="sec">${esc(g)} ` +
      `<span class="muted">${list.length}${urgent ? `, <span class="qprio urgent">${urgent} urgent</span>` : ""}</span></h2></summary>` +
      list.map(([r, i]) => bRow(r, i)).join("") + `</details>`;
  }
  html = `<div class="muted qstats">${n} open rows in ${groups.size} groups</div>` +
    (n ? html : html + `<div class="card muted">No row matches.</div>`);
  const y = $("board").scrollTop;
  el.innerHTML = html;
  $("board").scrollTop = y;
}

function renderBoard() {
  const el = $("board");
  if (!bst.feed) { el.innerHTML = `<div class="empty">${bst.err ? esc(bst.err) : "Loading..."}</div>`; return; }
  // The controls are drawn once per project list, so a re-read never eats what is being typed.
  const key = bst.feed.projects.map(bProjKey).join(",");
  if (key !== bst.controlsKey || !$("b-list")) {
    bst.controlsKey = key;
    el.innerHTML = bControls() + `<div id="b-list"></div>`;
  } else {
    $("b-msg").textContent = bst.msg;
    $("b-add").disabled = bst.busy;
    $("b-add").textContent = bst.busy ? "Adding..." : "Add";
  }
  drawBoardList();
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

function bSaveFilter() {
  const f = bst.filter;
  f.q = $("bf-q").value; f.profile = $("bf-profile").value; f.project = $("bf-project").value;
  f.lane = $("bf-lane").value; f.priority = $("bf-priority").value;
  drawBoardList();
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

function bTarget(r) {
  return { profile: r.profile, project: r.project, lane: r.lane, raw: r.raw };
}

$("board").addEventListener("click", (e) => {
  const t = e.target, rows = bst.feed ? bst.feed.rows : [];
  if (t.id === "b-add") { bAdd(); return; }
  if (t.id === "b-refresh") { bst.msg = ""; refreshBoard(); return; }
  const d = t.dataset;
  const r = rows[d.start || d.done || d.drop || d.promote || d.demote || d.move || d.edit || d.formgo || d.formcancel];
  if (!r) return;
  const k = bKey(r);
  if (d.start) { bWrite(Object.assign({ verb: "start" }, bTarget(r)), "Started."); return; }
  if (d.promote || d.demote) {
    const verb = d.promote ? "promote" : "demote";
    bWrite(Object.assign({ verb }, bTarget(r)), d.promote ? "One wave sooner." : "One wave later.");
    return;
  }
  const opened = d.done || d.drop || d.move || d.edit;
  if (opened) {
    bst.form = { k, kind: d.done ? "done" : d.drop ? "drop" : d.move ? "move" : "edit" };
    drawBoardList();
    const i = $("board").querySelector(`[data-forminput="${opened}"]`);
    if (i) i.focus();
    return;
  }
  if (d.formcancel) { bst.form = null; drawBoardList(); return; }
  if (d.formgo && bst.form) {
    const i = d.formgo, q = (a) => $("board").querySelector(`[data-${a}="${i}"]`);
    const v = q("forminput").value.trim(), kind = bst.form.kind;
    let body, ok;
    if (kind === "done" || kind === "drop") {
      const how = q("formkind").value;
      const need = { proof: "Give the proof (pr:N or a URL).", unverified: "Say why it is unverified.", why: "Say why it is dropped.", dup: "Give the id of the row it duplicates." };
      if (!v) { bst.msg = need[how]; renderBoard(); return; }
      body = { verb: kind, [how]: v }; ok = kind === "done" ? "Done." : "Dropped.";
    } else if (kind === "move") {
      const dest = q("movedest").value;
      if (!dest && !v) { bst.msg = "Pick a project, a wave, or both."; renderBoard(); return; }
      body = { verb: "move", dest, to: v }; ok = dest ? `Moved to ${dest}.` : `Moved to ${v}.`;
    } else {
      if (!v) { bst.msg = "Type the new text."; renderBoard(); return; }
      body = { verb: "edit", text: v }; ok = "Edited.";
    }
    bst.form = null;
    bWrite(Object.assign(body, bTarget(r)), ok);
  }
});
$("board").addEventListener("change", (e) => {
  if (e.target.closest(".badd")) bSaveDraft();
  else if (e.target.closest(".bfilter")) bSaveFilter();
});
$("board").addEventListener("input", (e) => {
  if (e.target.closest(".badd")) bSaveDraft();
  else if (e.target.id === "bf-q") bSaveFilter();
});
$("board").addEventListener("keydown", (e) => {
  if (e.key !== "Enter") return;
  if (e.target.id === "b-text") { e.preventDefault(); bAdd(); return; }
  const i = e.target.dataset.forminput;
  if (i != null) { e.preventDefault(); const b = $("board").querySelector(`[data-formgo="${i}"]`); if (b) b.click(); }
});
$("board").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) bst.open[e.target.dataset.k] = e.target.open;
}, true);

TABS.board = {
  show() { renderBoard(); refreshBoard(); },
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "board") refreshBoard(); },
};
