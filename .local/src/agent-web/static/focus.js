"use strict";
// The Focus tab: today's daily note with its `## Focus` lanes on top, from /api/focus (hub-core
// `focus`, the same reader as the hub's Focus tab). `#focus/<target>` opens another note in the
// same view: a day (`daily:2026-11-04`) or a `[[wikilink]]` target (`outbox`, `status/inbox`),
// which the notes CLI resolves and keeps inside the notes. Links in a note are plain `href="#..."`,
// so the browser's Back returns from one. Rendered draws the note; Raw is its markdown, to copy.
// Writing to the outbox is the Outbox tab (outbox.js); the head links there.
// Edit swaps the note for its markdown in a textarea; Save is one PUT /api/focus with the hash
// the page read (`notes put --base`), so a note that changed since (nvim, a sweep, a sync) is
// never overwritten: a 409 shows it as it is now beside yours, and you choose. The edit is kept
// in localStorage until saved or discarded, so a phone that drops the tab loses nothing.
// On `status/inbox` a Handled-today row's checkbox is live: ticking it is one POST /api/inbox/ack
// (`notes inbox ack`, the mark's one writer), and the page comes back with the row folded into
// `+N reviewed`, where unticking it brings it back.

const fcs = { data: null, err: null, raw: false, open: {}, copied: false, edit: null, saved: null };

const DRAFT = "focus-draft:";
function loadDraft(path) { try { return JSON.parse(localStorage.getItem(DRAFT + path) || "null"); } catch { return null; } }
function keepDraft(e) { try { localStorage.setItem(DRAFT + e.path, JSON.stringify({ base: e.base, text: e.text, at: Date.now() })); } catch { /* storage off: the edit lives in the page only */ } }
function dropDraft(path) { try { localStorage.removeItem(DRAFT + path); } catch { /* nothing kept */ } }

const focusTarget = () => st.arg || "daily";
const focusHref = (t) => "#focus/" + t.split("/").map(encodeURIComponent).join("/");

const refreshFocus = coalesce(async () => {
  const t = focusTarget();
  try {
    const d = await api("/api/focus?t=" + encodeURIComponent(t));
    // A read that finished after the reader moved on is not what the page asks for now.
    if (t !== focusTarget()) return;
    fcs.data = d; fcs.err = null;
  } catch (e) { fcs.err = e.message; }
  // A re-read while editing must not touch what is being typed: only the line under it changes.
  if (st.tab === "focus") { if (fcs.edit && fcs.edit.drawn) editStatus(); else renderFocus(); }
});

// A fold that is open the first time it is drawn (lanes but Done) stays as the reader leaves it.
function seed(k, open) { if (!(k in fcs.open)) fcs.open[k] = open; }

function laneFold(l) {
  const done = /^done$/i.test(l.name);
  const k = "lane:" + (l.name || "focus");
  seed(k, !done);
  const n = done ? l.done : l.open;
  const inner = l.markdown ? `<div class="md">${md(l.markdown, { notes: true })}</div>` : `<div class="muted">nothing here</div>`;
  return cfold(k, `<b>${esc(l.name || "Focus")}</b> <span class="muted">(${n})</span>`, inner, fcs.open);
}

// A note's markdown; only the inbox page's handled rows get live checkboxes.
const noteMd = (text) => md(text, { notes: true, ack: !!fcs.data && fcs.data.note.rel === "status/inbox" });

function sectionFold(s, open) {
  const k = "sec:" + (s.title || "top");
  seed(k, open);
  return cfold(k, `<b>${esc(s.title || "Top")}</b>`, `<div class="md">${noteMd(s.markdown)}</div>`, fcs.open);
}

function focusHead(v) {
  const n = v.note, f = v.focus;
  const day = n.date ? `${esc(n.title !== n.date && n.title ? n.title : n.date)}` : `<span title="${esc(n.path)}">${esc(n.rel)}</span>`;
  const counts = f ? ` <span class="muted">${f.open} open, ${f.done} done</span>` : "";
  const nav = [
    n.prev ? `<a class="btn sm" href="${focusHref("daily:" + n.prev)}" title="${esc(n.prev)}">&lt; day</a>` : "",
    n.next ? `<a class="btn sm" href="${focusHref("daily:" + n.next)}" title="${esc(n.next)}">day &gt;</a>` : "",
    st.arg ? `<button class="btn sm" data-f="back">Back</button><a class="btn sm" href="#focus">Today</a>` : "",
    `<button class="btn sm" data-f="refresh">Refresh</button>`,
    `<a class="btn sm" href="#outbox">Outbox</a>`,
    // The outbox's one editor is the Outbox tab (`notes put` refuses it).
    n.exists && !fcs.edit && n.rel !== "outbox" ? `<button class="btn sm" data-f="edit">${loadDraft(n.path) ? "Edit (draft)" : "Edit"}</button>` : "",
    fcs.saved && fcs.saved.path === n.path && !fcs.edit ? `<span class="muted">Saved ${esc(fcs.saved.at)}</span>` : "",
  ].join("");
  const seg = `<div class="seg"><button data-f="rendered"${fcs.raw ? "" : ` class="on"`}>Rendered</button><button data-f="raw"${fcs.raw ? ` class="on"` : ""}>Raw</button></div>`;
  return `<div class="bhead"><span>FOCUS ${day}${counts}</span><span class="opts">${nav}${fcs.edit ? "" : seg}</span></div>`;
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
    html += f.lanes.map(laneFold).join("");
    if (f.rollup) { seed("rollup", false); html += cfold("rollup", "<b>Rollup</b>", `<div class="md">${md(f.rollup, { notes: true })}</div>`, fcs.open); }
  }
  // A daily note's other sections fold away under Focus; a note opened from a link is the
  // thing being read, so it is open, with its untitled top drawn as is.
  for (const s of v.sections) {
    if (!f && !s.title) html += `<div class="md">${noteMd(s.markdown)}</div>`;
    else html += sectionFold(s, !f);
  }
  if (!html) html = `<div class="empty">This note is empty.</div>`;
  const links = n.links || [];
  if (links.length) {
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
  const el = $("focus");
  const v = fcs.data;
  if (!v) { el.innerHTML = `<div class="empty">${fcs.err ? esc(fcs.err) : "Reading the note..."}</div>`; return; }
  let html = focusHead(v);
  if (fcs.err) html += `<div class="panel down">${esc(fcs.err)}</div>`;
  paint(el, html + (fcs.edit ? editBody() : focusBody(v)), fcs.open);
  if (fcs.edit) fcs.edit.drawn = true;
}

$("focus").addEventListener("click", (e) => {
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
$("focus").addEventListener("change", (ev) => {
  const b = ev.target;
  if (b && b.dataset && b.dataset.ack && !fcs.edit) ackRow(b);
});
$("focus").addEventListener("input", (ev) => {
  const e = fcs.edit;
  if (!e || ev.target.id !== "f-edit") return;
  e.text = ev.target.value; keepDraft(e); editStatus();
});
$("focus").addEventListener("keydown", (ev) => {
  const e = fcs.edit;
  if (!e || ev.target.id !== "f-edit" || !(ev.ctrlKey || ev.metaKey) || (ev.key !== "s" && ev.key !== "Enter")) return;
  ev.preventDefault();
  saveEdit(e.stale ? e.stale.hash : e.base);
});
$("focus").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) fcs.open[e.target.dataset.k] = e.target.open;
}, true);

// Nothing watches ~/.notes (dashboards.md rule 9 is open on it), so the tab reads on every show,
// which a note link or a day button is too, and on Refresh.
TABS.focus = {
  show() {
    // A different note than the one drawn starts from its own top.
    if (fcs.data && fcs.data.note.target !== focusTarget().split(/[|#]/)[0].trim()) { fcs.data = null; fcs.copied = false; $("focus").scrollTop = 0; }
    // Another note than the one being edited closes the editor; the draft stays on the device.
    if (fcs.edit && fcs.edit.target !== focusTarget()) fcs.edit = null;
    if (fcs.edit) fcs.edit.drawn = false;
    renderFocus(); refreshFocus();
  },
  onEvent(ev) { if (st.tab === "focus" && ev.kind === "resync") refreshFocus(); },
};
