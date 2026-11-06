"use strict";
// The Daily tab: today's daily note, its links as a row of buttons, then its `## Focus` lanes as
// cards, from /api/focus (hub-core `focus`, the same reader as the hub's Daily tab).
// `#daily/<target>` opens another note in the same view: a day (`daily:2026-11-04`) or a
// `[[wikilink]]` target (`status/inbox`), which the notes CLI resolves and keeps inside the notes.
// `#daily/outbox` is the outbox editor (outbox.js) in its place, not the note. Links in a note are
// plain `href="#..."`, so the browser's Back returns from one. Rendered draws the note; Raw is its
// markdown, to copy. Project tasks are the Projects tab's; this view is the note alone.
// Edit swaps the note for its markdown in a textarea; Save is one PUT /api/focus with the hash
// the page read (`notes put --base`), so a note that changed since (nvim, a sweep, a sync) is
// never overwritten: a 409 shows it as it is now beside yours, and you choose. The edit is kept
// in localStorage until saved or discarded, so a phone that drops the tab loses nothing.

const fcs = { data: null, err: null, raw: false, open: {}, copied: false, edit: null, saved: null };

const DRAFT = "focus-draft:";
function loadDraft(path) { try { return JSON.parse(localStorage.getItem(DRAFT + path) || "null"); } catch { return null; } }
function keepDraft(e) { try { localStorage.setItem(DRAFT + e.path, JSON.stringify({ base: e.base, text: e.text, at: Date.now() })); } catch { /* storage off: the edit lives in the page only */ } }
function dropDraft(path) { try { localStorage.removeItem(DRAFT + path); } catch { /* nothing kept */ } }

const focusTarget = () => st.arg || "daily";
const focusHref = (t) => "#daily/" + t.split("/").map(encodeURIComponent).join("/");

const refreshFocus = coalesce(async () => {
  const t = focusTarget();
  try {
    const d = await api("/api/focus?t=" + encodeURIComponent(t));
    // A read that finished after the reader moved on is not what the page asks for now.
    if (t !== focusTarget()) return;
    fcs.data = d; fcs.err = null;
  } catch (e) { fcs.err = e.message; }
  // A re-read while editing must not touch what is being typed: only the line under it changes.
  if (st.tab === "daily" && !outboxOpen()) { if (fcs.edit && fcs.edit.drawn) editStatus(); else renderFocus(); }
});

// A fold that is open the first time it is drawn (lanes but Done) stays as the reader leaves it.
function seed(k, open) { if (!(k in fcs.open)) fcs.open[k] = open; }

const outboxOpen = () => st.arg === "outbox";

// One lane of the Focus block as a card: its name and count, its tasks; Done starts folded and an
// empty lane says so in one line. Urgent and High take the priority tints Queue uses.
function laneCard(l) {
  const done = /^done$/i.test(l.name);
  const k = "lane:" + (l.name || "focus");
  seed(k, !done);
  const n = done ? l.done : l.open;
  const tint = /^urgent$/i.test(l.name) ? " urgent" : /^high$/i.test(l.name) ? " high" : done ? " done" : "";
  const head = `<span class="dln">${esc(l.name || "Focus")}</span><span class="dlc">${n}</span>`;
  if (!l.markdown) return `<div class="dlane empty${tint}"><div class="dlh">${head}<span class="muted">nothing here</span></div></div>`;
  return `<details class="dlane${tint}" data-k="${esc(k)}"${fcs.open[k] ? " open" : ""}><summary class="dlh">${head}</summary>` +
    `<div class="md">${md(l.markdown, { notes: true })}</div></details>`;
}

// A link's short name for a button: its label when it has one, else the last part of its path
// that is a word (not a date, a number, an index or a _folder): `status/inbox` is Inbox.
function linkName(l) {
  if (l.label && l.label !== l.target) return l.label;
  const parts = l.target.split("/").reverse();
  const w = parts.find((p) => !/^(\d[\d-]*|index|moc|_.*)$/i.test(p)) || parts[0];
  return w.charAt(0).toUpperCase() + w.slice(1).replace(/[-_]/g, " ");
}

// The note's links as one row of buttons, the outbox first (always there, with its waiting count
// when the outbox has been read); each opens in this view, so Back returns.
function linksRow(links) {
  const seen = new Set(["outbox"]);
  const ob = obx.view ? ` <span class="dlc">${obx.view.doc.waiting}</span>` : "";
  const rest = links.filter((l) => !seen.has(l.target) && seen.add(l.target));
  return `<nav class="dlinks"><a class="dlink out" href="#daily/outbox">Outbox${ob}</a>${rest.map((l) =>
    `<a class="dlink${l.exists ? "" : " missing"}" href="${focusHref(l.target)}" title="${esc(l.target)}${l.exists ? "" : " (no such note)"}">${esc(linkName(l))}</a>`).join("")}</nav>`;
}

function sectionFold(s, open) {
  const k = "sec:" + (s.title || "top");
  seed(k, open);
  return cfold(k, `<b>${esc(s.title || "Top")}</b>`, `<div class="md">${md(s.markdown, { notes: true })}</div>`, fcs.open);
}

// The head: which note (a day reads as its date), its open and done counts, then the day
// steps, Edit and Rendered/Raw. A note opened from a link gets Back.
function focusHead(v) {
  const n = v.note, f = v.focus;
  const day = n.date ? esc(n.title !== n.date && n.title ? n.title : n.date) : `<span title="${esc(n.path)}">${esc(n.rel)}</span>`;
  const counts = f ? `<span class="muted">${f.open} open, ${f.done} done</span>` : "";
  const nav = [
    st.arg && !n.date ? `<button class="btn sm" data-f="back">Back</button>` : "",
    n.prev ? `<a class="btn sm" href="${focusHref("daily:" + n.prev)}" title="${esc(n.prev)}" aria-label="Day before">&lt;</a>` : "",
    st.arg ? `<a class="btn sm" href="#daily">Today</a>` : "",
    n.next ? `<a class="btn sm" href="${focusHref("daily:" + n.next)}" title="${esc(n.next)}" aria-label="Day after">&gt;</a>` : "",
    `<button class="btn sm" data-f="refresh">Refresh</button>`,
    // The outbox's one editor is #daily/outbox (`notes put` refuses it).
    n.exists && !fcs.edit && n.rel !== "outbox" ? `<button class="btn sm" data-f="edit">${loadDraft(n.path) ? "Edit (draft)" : "Edit"}</button>` : "",
    fcs.saved && fcs.saved.path === n.path && !fcs.edit ? `<span class="muted">Saved ${esc(fcs.saved.at)}</span>` : "",
  ].join("");
  const seg = `<div class="seg"><button data-f="rendered"${fcs.raw ? "" : ` class="on"`}>Rendered</button><button data-f="raw"${fcs.raw ? ` class="on"` : ""}>Raw</button></div>`;
  return `<div class="dhead"><div class="dtitle"><h2>${day}</h2>${counts}</div><div class="opts">${nav}${fcs.edit ? "" : seg}</div></div>`;
}

function focusBody(v) {
  const n = v.note;
  if (!n.exists) return `<div class="empty">${n.date ? `No note for ${esc(n.date)} yet.` : `No note at ${esc(n.rel)}.`}</div>`;
  if (fcs.raw) {
    return `<div class="opts"><button class="btn sm" data-f="copy">${fcs.copied ? "Copied" : "Copy"}</button>` +
      `<span class="muted">${esc(n.path)}</span></div><pre class="raw">${esc(n.markdown)}</pre>`;
  }
  const links = n.links || [];
  // A day leads with its links; another note keeps them at its foot.
  let html = n.date ? linksRow(links) : "";
  const f = v.focus;
  if (f) {
    // A nameless lane with no words in it (a stray bracket or rule left in the note) is not drawn.
    html += f.lanes.filter((l) => l.name || /\w/.test(l.markdown || "")).map(laneCard).join("");
    if (f.rollup) { seed("rollup", false); html += cfold("rollup", "<b>Rollup</b>", `<div class="md">${md(f.rollup, { notes: true })}</div>`, fcs.open); }
  }
  // A daily note's other sections fold away under Focus; a note opened from a link is the
  // thing being read, so it is open, with its untitled top drawn as is.
  for (const s of v.sections) {
    if (!f && !s.title) html += `<div class="md">${md(s.markdown, { notes: true })}</div>`;
    else html += sectionFold(s, !f);
  }
  if (!html) html = `<div class="empty">This note is empty.</div>`;
  if (links.length && !n.date) {
    html += `<h2 class="sec">Links in this note</h2><div class="opts">${links.map((l) =>
      `<a class="wl${l.exists ? "" : " missing"}" href="${focusHref(l.target)}" title="${esc(l.target)}${l.exists ? "" : " (no such note)"}">${esc(l.label || l.target)}</a>`).join("")}</div>`;
  }
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

async function saveEdit(base) {
  const e = fcs.edit;
  if (!e || e.saving) return;
  e.saving = true; e.err = null; renderFocus();
  try {
    const r = await fetch("/api/focus", { method: "PUT", credentials: "same-origin", headers: { "content-type": "application/json" }, body: JSON.stringify({ t: e.target, base, text: e.text }) });
    if (r.status === 401) { location.reload(); throw new Error("Signed out. Reloading to sign in again; your edit is kept on this device."); }
    if (r.ok) {
      const v = await r.json();
      dropDraft(e.path); fcs.edit = null; fcs.data = v;
      fcs.saved = { path: v.note.path, at: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) };
    } else if (r.status === 409) {
      const v = await r.json();
      fcs.data = v; e.stale = v.note; e.saving = false;
    } else {
      const said = ((await r.text()) || r.statusText).trim().slice(0, 300);
      throw new Error(`Could not save ${e.rel} (HTTP ${r.status})${said ? ": " + said : ""}. Your edit is still here and kept on this device.`);
    }
  } catch (err) { e.err = err.message; e.saving = false; }
  renderFocus();
}

function renderFocus() {
  const el = $("d-note");
  const v = fcs.data;
  if (!v) { el.innerHTML = `<div class="empty">${fcs.err ? esc(fcs.err) : "Reading the note..."}</div>`; return; }
  let html = focusHead(v);
  if (fcs.err) html += `<div class="panel down">${esc(fcs.err)}</div>`;
  paint(el, html + (fcs.edit ? editBody() : focusBody(v)), fcs.open);
  if (fcs.edit) fcs.edit.drawn = true;
}

$("d-note").addEventListener("click", (e) => {
  const b = e.target.closest("[data-f]");
  if (!b) return;
  const f = b.dataset.f;
  if (f === "back") history.back();
  else if (f === "refresh") refreshFocus();
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
    if (outboxOpen()) { OUTBOX.show(); return; }
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
