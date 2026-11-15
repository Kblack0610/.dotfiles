"use strict";
// The Daily tab: a nav (dayNav), then today's daily note, its `## Focus` lanes as cards, from
// /api/focus (hub-core `focus`, the same reader as the hub's Daily tab).
// `#daily/<target>` opens another note in the same view: a day (`daily:2026-11-04`) or a
// `[[wikilink]]` target (`status/inbox`), which the notes CLI resolves and keeps inside the notes.
// `#daily/outbox` is the outbox editor (outbox.js) in its place, not the note. Links in a note are
// plain `href="#..."`, so the browser's Back returns from one. Rendered draws the note; Raw is its
// markdown, to copy. Project tasks are the Projects tab's; this view is the note alone.
// Edit swaps the note for its markdown in a textarea; Save is one PUT /api/focus with the hash
// the page read (`notes put --base`), so a note that changed since (nvim, a sweep, a sync) is
// never overwritten: a 409 shows it as it is now beside yours, and you choose. The edit is kept
// in localStorage until saved or discarded, so a phone that drops the tab loses nothing.
// On `status/inbox` a Handled-today row's checkbox is live: ticking it is one POST /api/inbox/ack
// (`notes inbox ack`, the mark's one writer), and the page comes back with the row folded into
// `+N reviewed`, where unticking it brings it back.
// On a day note each task row is live: its box ticks or unticks it, `-` removes it (with Undo),
// and each named lane but Done has a `+` line that adds a task tagged with the lane. Each is the
// one line changed in the note as read, saved like Edit's Save (`notes put --base`), so a note
// that changed since is shown as it is now and nothing is written over it.
// The day's Briefing comes with the day (hub-core View.brief) and is drawn as one fold after
// the lanes. Each lane and section carries its lines in the note (`line`, `lines`), which is
// where a row action writes.

// `links` are the nav's places from the last read (View.places: a day's own links, else
// today's), kept while the outbox is open or a read's places are null; null until a read. `undo` is the note as it was
// before the last row removed.
const fcs = { data: null, err: null, raw: false, open: {}, copied: false, edit: null, saved: null, links: null, busy: false, undo: null };

const DRAFT = "focus-draft:";
function loadDraft(path) { try { return JSON.parse(localStorage.getItem(DRAFT + path) || "null"); } catch { return null; } }
function keepDraft(e) { try { localStorage.setItem(DRAFT + e.path, JSON.stringify({ base: e.base, text: e.text, at: Date.now() })); } catch { /* storage off: the edit lives in the page only */ } }
function dropDraft(path) { try { localStorage.removeItem(DRAFT + path); } catch { /* nothing kept */ } }

const focusTarget = () => st.arg || "daily";
const focusHref = (t) => "#daily/" + t.split("/").map(encodeURIComponent).join("/");
const readNote = (t) => api("/api/focus?t=" + encodeURIComponent(t));
const isDone = (name) => /^done$/i.test(name || "");

const refreshFocus = coalesce(async () => {
  const t = focusTarget();
  try {
    const d = await readNote(t);
    // A read that finished after the reader moved on is not what the page asks for now.
    if (t !== focusTarget()) return;
    fcs.data = d; fcs.err = null;
  } catch (e) { fcs.err = e.message; }
  redraw();
});
// A re-read while editing must not touch what is being typed: only the line under it changes.
function redraw() {
  if (st.tab !== "daily") return;
  if (outboxOpen()) { dayNav(); return; }
  if (fcs.edit && fcs.edit.drawn) { editStatus(); dayNav(); } else renderFocus();
}

// A fold that is open the first time it is drawn (lanes but Done) stays as the reader leaves it.
function seed(k, open) { if (!(k in fcs.open)) fcs.open[k] = open; }

const outboxOpen = () => st.arg === "outbox";

// The day's briefing, read whole with the day, as an open fold; a day without one draws none.
function briefFold() {
  const b = fcs.data.brief;
  if (!b || !b.note.exists) return "";
  seed("brief", true);
  const body = b.sections.map((s) => (s.title ? `<h3>${esc(s.title)}</h3>` : "") + md(s.markdown, { notes: true })).join("");
  return cfold("brief", `<b>Briefing</b> <a class="muted" href="${focusHref(b.note.target)}">open</a>`, `<div class="md">${body}</div>`, fcs.open);
}

const liveRows = () => !!fcs.data && !!fcs.data.note.date && !fcs.edit;

// A lane's `+` line: Done takes no new rows, and the rollup is another note's.
function addRow(l) {
  if (!liveRows() || isDone(l.name)) return "";
  return `<form class="tadd" data-id="${esc(l.name)}"><button class="tplus" title="Add a task to ${esc(l.name)}" aria-label="Add a task to ${esc(l.name)}">+</button>` +
    `<input name="t" data-free placeholder="Add to ${esc(l.name)}" autocomplete="off" enterkeyhint="done"></form>`;
}

// One lane of the Focus block as a card: its name and count, its tasks; Done starts folded and an
// empty lane says so in one line. Urgent and High take the priority tints Queue uses.
function laneCard(l) {
  const done = isDone(l.name);
  const k = "lane:" + l.name;
  seed(k, !done);
  const n = done ? l.done : l.open;
  const tint = /^urgent$/i.test(l.name) ? " urgent" : /^high$/i.test(l.name) ? " high" : done ? " done" : "";
  const head = `<span class="dln">${esc(l.name)}</span><span class="dlc">${n}</span>`;
  if (!l.markdown) {
    const add = addRow(l);
    return `<div class="dlane empty${tint}"><div class="dlh">${head}<span class="muted">nothing here</span></div>${add ? `<div class="md">${add}</div>` : ""}</div>`;
  }
  // Every task in the Urgent lane carries #urgent; the lane says it once.
  const own = new RegExp(`(^|\\s)#${l.name.replace(/\W/g, "")}(?![\\w:/-])`, "gim");
  const text = l.markdown.replace(own, "$1");
  const at = liveRows() ? l.lines : null;
  return `<details class="dlane${tint}" data-k="${esc(k)}"${fcs.open[k] ? " open" : ""}><summary class="dlh">${head}</summary>` +
    `<div class="md">${md(text, { notes: true, rows: at })}${addRow(l)}</div></details>`;
}

// A link's short name for a button: its label when it has one, else the last part of its path
// that is a word (not a date, a number, an index or a _folder): `status/inbox` is Inbox.
function linkName(l) {
  if (l.label && l.label !== l.target) return l.label;
  const parts = l.target.split("/").reverse();
  const w = parts.find((p) => !/^(\d[\d-]*|index|moc|_.*)$/i.test(p)) || parts[0];
  return w.charAt(0).toUpperCase() + w.slice(1).replace(/[-_]/g, " ");
}

// The places the nav always has, Daily first; the read's places follow them.
const PLACES = [{ target: "daily", name: "Daily" }, { target: "outbox", name: "Outbox" }, { target: "status/inbox", name: "Inbox" }];

// The open note's parts the nav jumps to: each lane with something in it, the rollup and each
// titled section. A day's Links footer is not one: the nav lists those links already.
function noteParts() {
  const v = fcs.data;
  if (!v || !v.note.exists || fcs.raw || fcs.edit || outboxOpen()) return [];
  const f = v.focus, parts = [];
  if (f) {
    for (const l of f.lanes) if (l.markdown) parts.push({ k: "lane:" + l.name, name: l.name, n: isDone(l.name) ? l.done : l.open });
    if (v.note.date && v.brief && v.brief.note.exists) parts.push({ k: "brief", name: "Briefing", target: v.brief.note.target });
    if (f.rollup) parts.push({ k: "rollup", name: "Rollup" });
  }
  for (const s of v.sections) if (s.title && !(v.note.date && s.title === "Links")) parts.push({ k: "sec:" + s.title, name: s.title });
  return parts;
}

// Daily's one nav: a column beside the note on a wide screen, a strip that scrolls sideways on a
// phone (app.css). The places (Daily, Outbox with its waiting count, Inbox, then the read's
// places in their order, each once) and then the open note's parts. Only the view open now is
// marked; each place opens in this view, so Back returns.
function dayNav() {
  if (fcs.data && fcs.data.places) fcs.links = fcs.data.places;
  const t = focusTarget().split(/[|#]/)[0].trim();
  const cur = outboxOpen() ? "outbox" : /^daily(:|$)/.test(t) ? "daily" : t;
  const parts = noteParts();
  // A briefing drawn on the page is a part of it, not a second place beside it.
  const seen = new Set(parts.filter((p) => p.target).map((p) => p.target));
  const places = [...PLACES, ...(fcs.links || []).map((l) => ({ target: l.target, name: linkName(l), missing: !l.exists }))]
    .filter((p) => !seen.has(p.target) && seen.add(p.target));
  const n = (p) => (p.target === "outbox" && obx.view ? ` <span class="dlc">${obx.view.doc.waiting}</span>` : "");
  let html = places.map((p) => `<a class="dn${p.missing ? " missing" : ""}" href="${p.target === "daily" ? "#daily" : focusHref(p.target)}"` +
    ` title="${esc(p.target)}${p.missing ? " (no such note)" : ""}"${p.target === cur ? ` aria-current="page"` : ""}>${esc(p.name)}${n(p)}</a>`).join("");
  if (parts.length) {
    html += `<span class="dng">This note</span>` + parts.map((p) =>
      `<button class="dn part" data-jump="${esc(p.k)}">${esc(p.name)}${p.n != null ? ` <span class="dlc">${p.n}</span>` : ""}</button>`).join("");
  }
  $("d-nav").innerHTML = html;
}

// A note's markdown; only the inbox page's handled rows get live checkboxes.
// On a day note a titled section's task rows are live too.
const noteMd = (text, rows) => md(text, { notes: true, ack: !!fcs.data && fcs.data.note.rel === "status/inbox", rows });

function sectionFold(s, open) {
  const k = "sec:" + (s.title || "top");
  seed(k, open);
  const at = liveRows() && s.title ? s.lines : null;
  return cfold(k, `<b>${esc(s.title || "Top")}</b>`, `<div class="md">${noteMd(s.markdown, at)}</div>`, fcs.open);
}

// The head: which note (a day reads as its date), its open and done counts, then the day
// steps, Edit and Rendered/Raw. The nav is the way to today and back to it.
function focusHead(v) {
  const n = v.note, f = v.focus;
  const day = n.date ? (n.title !== n.date && n.title ? n.title : n.date) : n.rel;
  const counts = f ? `${f.open} open, ${f.done} done` : null;
  const nav = [
    n.prev ? `<a class="btn sm" href="${focusHref("daily:" + n.prev)}" title="${esc(n.prev)}" aria-label="Day before">&lt;</a>` : "",
    n.next ? `<a class="btn sm" href="${focusHref("daily:" + n.next)}" title="${esc(n.next)}" aria-label="Day after">&gt;</a>` : "",
    `<button class="btn sm" data-f="refresh">Refresh</button>`,
    // The outbox's one editor is #daily/outbox (`notes put` refuses it).
    n.exists && !fcs.edit && n.rel !== "outbox" ? `<button class="btn sm" data-f="edit">${loadDraft(n.path) ? "Edit (draft)" : "Edit"}</button>` : "",
    fcs.saved && fcs.saved.path === n.path && !fcs.edit ? `<span class="muted">Saved ${esc(fcs.saved.at)}</span>` : "",
  ].join("");
  const seg = `<div class="seg"><button data-f="rendered"${fcs.raw ? "" : ` class="on"`}>Rendered</button><button data-f="raw"${fcs.raw ? ` class="on"` : ""}>Raw</button></div>`;
  return `<div class="dhead">${secHead("", day, counts)}<div class="opts">${nav}${fcs.edit ? "" : seg}</div></div>`;
}

function focusBody(v) {
  const n = v.note;
  if (!n.exists) return `<div class="empty">${n.date ? `No note for ${esc(n.date)} yet.` : `No note at ${esc(n.rel)}.`}</div>`;
  if (fcs.raw) {
    return `<div class="opts"><button class="btn sm" data-f="copy">${fcs.copied ? "Copied" : "Copy"}</button>` +
      `<span class="muted">${esc(n.path)}</span></div><pre class="raw">${esc(n.markdown)}</pre>`;
  }
  let html = "";
  const f = v.focus;
  if (f) {
    html += f.lanes.map(laneCard).join("");
    if (n.date) html += briefFold();
    if (f.rollup) { seed("rollup", false); html += cfold("rollup", "<b>Rollup</b>", `<div class="md">${md(f.rollup, { notes: true })}</div>`, fcs.open); }
  }
  // A daily note's other sections fold away under Focus; a note opened from a link is the
  // thing being read, so it is open, with its untitled top drawn as is. A day's Links footer
  // is the nav's places already.
  for (const s of v.sections) {
    if (n.date && s.title === "Links") continue;
    if (!f && !s.title) html += `<div class="md">${noteMd(s.markdown)}</div>`;
    else html += sectionFold(s, !f);
  }
  if (!html) html = `<div class="empty">This note is empty.</div>`;
  return html;
}

// The line under the textarea: what Save will do now.
function editLine() {
  const e = fcs.edit, now = fcs.data && fcs.data.note;
  if (e.saving) return "Saving...";
  if (!e.stale && now && now.path === e.path && now.hash !== e.base) return "This note changed elsewhere since you opened it; Save will show both.";
  return e.text === e.orig ? "No changes yet." : "Unsaved changes, kept on this device until you save.";
}
function editStatus() { const s = $("f-edit-st"); if (s && fcs.edit) s.textContent = editLine(); }

function editBody() {
  const e = fcs.edit;
  let html = `<div class="opts"><span class="muted">Editing ${esc(e.rel)}</span><button class="btn sm" data-f="cancel">Cancel</button></div>`;
  if (e.stale) {
    seed("edit:now", false);
    html += `<div class="panel down">This note changed after you opened it. Nothing was written.</div>` +
      cfold("edit:now", "<b>The note as it is now</b>", `<pre class="raw">${esc(e.stale.markdown)}</pre>`, fcs.open) +
      `<div class="opts"><button class="btn sm primary" data-f="over"${e.saving ? " disabled" : ""}>Save mine over it</button>` +
      `<button class="btn sm" data-f="copymine">${e.copied ? "Copied" : "Copy mine"}</button><button class="btn sm" data-f="discard">Discard mine</button></div>`;
  }
  html += `<textarea id="f-edit" spellcheck="false" autocapitalize="off">${esc(e.text)}</textarea>`;
  html += `<div class="opts">${e.stale ? "" : `<button class="btn sm primary" data-f="save"${e.saving ? " disabled" : ""}>Save</button>`}<span id="f-edit-st" class="muted">${esc(editLine())}</span></div>`;
  if (e.err) html += `<div class="err">${esc(e.err)}</div>`;
  return html;
}

// Open the editor on the note drawn. A kept draft comes back; one made on an older read of the
// note opens straight on the changed view, the draft beside the note as it is now.
function startEdit() {
  const n = fcs.data.note, d = loadDraft(n.path);
  fcs.edit = { path: n.path, rel: n.rel, target: focusTarget(), orig: n.markdown, base: d ? d.base : n.hash, text: d ? d.text : n.markdown, stale: d && d.base !== n.hash ? n : null, saving: false, err: null };
  fcs.saved = null;
  renderFocus();
}

function endEdit() { if (fcs.edit) dropDraft(fcs.edit.path); fcs.edit = null; renderFocus(); }
// Throwing typed text away asks first; nothing typed, nothing to ask.
function discardEdit() { const e = fcs.edit; if (e && e.text !== e.orig && !confirm("Throw away your edit of " + e.rel + "?")) return; endEdit(); }

// One write of a whole note over the hash it was read at; a 409 answers with it as it is now.
const putNote = (t, base, text, rel) => putBase("/api/focus", { t, base, text }, rel);

async function saveEdit(base) {
  const e = fcs.edit;
  if (!e || e.saving) return;
  e.saving = true; e.err = null; renderFocus();
  try {
    const { doc: v, stale: conflict } = await putNote(e.target, base, e.text, e.rel);
    if (!conflict) {
      dropDraft(e.path); fcs.edit = null; fcs.data = v;
      fcs.saved = { path: v.note.path, at: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) };
    } else { fcs.data = v; e.stale = v.note; e.saving = false; }
  } catch (err) { e.err = err.message + " Your edit is still here and kept on this device."; e.saving = false; }
  renderFocus();
}

// A row action: `change` turns the note's lines into the new lines, or null when the line it
// was drawn from is not what it was (the note moved under the page), and nothing is written.
// `removed` names a removed row for Undo; `base` is the hash to write over (the page's read).
// True when the change was written.
const TASK = /^(\s*[-*+]\s+\[)([ xX/])(\]\s)/;
async function rowEdit(change, removed, base) {
  const v = fcs.data;
  if (!v || !liveRows()) { renderFocus(); return false; }
  if (fcs.busy) { fcs.err = "Still saving the last change; do that again in a moment."; renderFocus(); return false; }
  // A day's own target, never the `daily` alias, which names another day after midnight.
  const t = v.note.date ? "daily:" + v.note.date : v.note.target;
  const before = v.note.markdown, lines = change(before.split("\n"));
  if (!lines) {
    try { fcs.data = await readNote(t); } catch { /* the page keeps what it has */ }
    fcs.err = "That row is not where the page drew it; here is the note as it is now.";
    renderFocus();
    return false;
  }
  let ok = false;
  fcs.busy = true; fcs.undo = null;
  try {
    const { doc: view, stale: conflict } = await putNote(t, base || v.note.hash, lines.join("\n"), v.note.rel);
    fcs.data = view;
    fcs.err = conflict ? "The note changed somewhere else, so nothing was written; here it is as it is now." : null;
    if (!conflict && removed) fcs.undo = { path: view.note.path, what: removed, text: before, base: view.note.hash };
    ok = !conflict;
  } catch (err) { fcs.err = err.message; }
  fcs.busy = false;
  renderFocus();
  return ok;
}

// A task's box: tick is [x], untick is [ ] (a doing row ticked is done).
function tickRow(box) {
  const n = Number(box.dataset.ln);
  return rowEdit((ls) => {
    const m = TASK.exec(ls[n] || "");
    if (!m) return null;
    ls[n] = ls[n].replace(TASK, `$1${box.checked ? "x" : " "}$3`);
    return ls;
  });
}

// `-` removes the row and the rows nested under it.
function removeRow(n) {
  const ls = fcs.data.note.markdown.split("\n");
  const m = TASK.exec(ls[n] || "");
  if (!m) return rowEdit(() => null);
  const ind = (l) => l.length - l.trimStart().length;
  // Its children run while lines are deeper than it; a blank line inside them does not end them.
  let end = n + 1;
  for (let j = n + 1; j < ls.length; j++) {
    if (!ls[j].trim()) continue;
    if (ind(ls[j]) <= ind(ls[n])) break;
    end = j + 1;
  }
  const what = ls[n].slice(m[0].length).replace(/\s#[\w:/-]+/g, "").trim().slice(0, 60);
  return rowEdit((l) => (l.splice(n, end - n), l), `"${what}"`);
}

// `+` adds `- [ ] <text>` at the end of the lane, tagged #urgent, #high or #low as the lane is
// (the tag is what the Focus sweep files a task by) unless the text names one itself.
function addTask(lane, text) {
  const l = fcs.data.focus && fcs.data.focus.lanes.find((x) => x.name === lane);
  if (!l || !text.trim()) return Promise.resolve(false);
  const tag = /^(urgent|high|low)$/i.test(lane) && !/(^|\s)#(urgent|high|low)\b/i.test(text) ? " #" + lane.toLowerCase() : "";
  const row = `- [ ] ${text.trim()}${tag}`;
  // Below the lane's last line, or its heading when it has none; a heading that is not one
  // means the page's lines are not this note's.
  return rowEdit((ls) => {
    const after = l.lines.length ? l.lines[l.lines.length - 1] : l.line;
    if (!/^#/.test(ls[l.line] || "") || !(after < ls.length)) return null;
    ls.splice(after + 1, 0, row + (ls[after].endsWith("\r") ? "\r" : ""));
    return ls;
  });
}

// Undo writes the note back as it was, over the hash the remove left; a change since writes nothing.
function undoRemove() {
  const u = fcs.undo;
  return u ? rowEdit(() => u.text.split("\n"), null, u.base) : Promise.resolve(false);
}

function renderFocus() {
  const el = $("d-note");
  const v = fcs.data;
  if (!v) { el.innerHTML = `<div class="empty">${fcs.err ? esc(fcs.err) : "Reading the note..."}</div>`; return; }
  let html = focusHead(v);
  if (fcs.err) html += `<div class="panel down">${esc(fcs.err)}</div>`;
  if (fcs.undo && fcs.undo.path === v.note.path && !fcs.edit) html += `<div class="opts tundo"><span class="muted">Removed ${esc(fcs.undo.what)}</span><button class="btn sm" data-f="undo">Undo</button></div>`;
  // A task being typed into a lane's `+` line survives a redraw.
  keepTyping("form.tadd", () => paint(el, html + (fcs.edit ? editBody() : focusBody(v)), fcs.open));
  if (fcs.edit) fcs.edit.drawn = true;
  dayNav();
}

$("d-note").addEventListener("click", (e) => {
  const rm = e.target.closest("[data-rm]");
  if (rm) { e.preventDefault(); removeRow(Number(rm.dataset.rm)); return; }
  const b = e.target.closest("[data-f]");
  if (!b) return;
  const f = b.dataset.f;
  if (f === "refresh") refreshFocus();
  else if (f === "undo") undoRemove();
  else if (f === "rendered" || f === "raw") { fcs.raw = f === "raw"; fcs.copied = false; renderFocus(); }
  else if (f === "edit" && fcs.data) startEdit();
  else if (f === "cancel" || f === "discard") discardEdit();
  else if (f === "save" && fcs.edit) saveEdit(fcs.edit.base);
  else if (f === "over" && fcs.edit && fcs.edit.stale) saveEdit(fcs.edit.stale.hash);
  else if (f === "copymine" && fcs.edit) {
    const e = fcs.edit;
    navigator.clipboard.writeText(e.text).then(() => { e.copied = true; renderFocus(); }, (err) => { e.err = "copy: " + err.message; renderFocus(); });
  }
  else if (f === "copy" && fcs.data) {
    navigator.clipboard.writeText(fcs.data.note.markdown).then(() => { fcs.copied = true; renderFocus(); }, (err) => { fcs.err = "copy: " + err.message; renderFocus(); });
  }
});
// A tick or untick on the inbox page. The box is locked until the answer redraws the page; a
// refusal says why and the redraw puts the box back as the page has it.
async function ackRow(box) {
  box.disabled = true;
  try {
    fcs.data = await post("/api/inbox/ack", { key: box.dataset.ack, ack: box.checked });
    fcs.err = null;
  } catch (err) { fcs.err = err.message; }
  renderFocus();
}
$("d-note").addEventListener("change", (ev) => {
  const b = ev.target;
  if (b && b.dataset && b.dataset.ack && !fcs.edit) ackRow(b);
  else if (b && b.dataset && b.dataset.ln) tickRow(b);
});
$("d-note").addEventListener("submit", (ev) => {
  const form = ev.target.closest("form.tadd");
  if (!form) return;
  ev.preventDefault();
  const input = form.elements.t;
  const text = input.value;
  if (!text.trim()) { input.focus(); return; }
  // Cleared before the write so the redraw does not keep it; put back when nothing was written.
  input.value = "";
  addTask(form.dataset.id, text).then((ok) => {
    if (ok) return;
    const again = [...$("d-note").querySelectorAll("form.tadd")].find((f) => f.dataset.id === form.dataset.id);
    if (again && !again.elements.t.value) again.elements.t.value = text;
  });
});
$("d-note").addEventListener("input", (ev) => {
  const e = fcs.edit;
  if (!e || ev.target.id !== "f-edit") return;
  e.text = ev.target.value; keepDraft(e); editStatus();
});
$("d-note").addEventListener("keydown", (ev) => {
  const e = fcs.edit;
  if (!e || ev.target.id !== "f-edit" || !(ev.ctrlKey || ev.metaKey) || (ev.key !== "s" && ev.key !== "Enter")) return;
  ev.preventDefault();
  saveEdit(e.stale ? e.stale.hash : e.base);
});
// A part of the note in the nav opens its fold and scrolls to it.
$("d-nav").addEventListener("click", (e) => {
  const b = e.target.closest("[data-jump]");
  if (!b) return;
  const k = b.dataset.jump;
  const d = [...$("d-note").querySelectorAll("[data-k]")].find((x) => x.dataset.k === k);
  if (!d) return;
  d.open = true; fcs.open[k] = true;
  d.scrollIntoView({ block: "start", behavior: "smooth" });
});
OUTBOX.changed = () => { if (st.tab === "daily") dayNav(); };

$("d-note").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) fcs.open[e.target.dataset.k] = e.target.open;
}, true);

// Nothing watches ~/.notes (dashboards.md rule 9 is open on it), so the tab reads on every show,
// which a note link or a day button is too, and on Refresh.
// `#daily/outbox` swaps the note for the outbox editor (outbox.js OUTBOX), which keeps its own
// pushed reads.
TABS.daily = {
  show() {
    $("d-note").hidden = outboxOpen();
    $("outbox").hidden = !outboxOpen();
    dayNav();
    // A page opened straight on the outbox has read no note yet; one read brings the nav's places.
    if (outboxOpen()) { OUTBOX.show(); if (!fcs.links) refreshFocus(); return; }
    // A different note than the one drawn starts from its own top.
    if (fcs.data && fcs.data.note.target !== focusTarget().split(/[|#]/)[0].trim()) { fcs.data = null; fcs.copied = false; $("daily").scrollTop = 0; }
    // Another note than the one being edited closes the editor; the draft stays on the device.
    if (fcs.edit && fcs.edit.target !== focusTarget()) fcs.edit = null;
    if (fcs.edit) fcs.edit.drawn = false;
    renderFocus(); refreshFocus();
  },
  onEvent(ev) {
    OUTBOX.onEvent(ev);
    if (st.tab === "daily" && !outboxOpen() && ev.kind === "resync") refreshFocus();
  },
};
