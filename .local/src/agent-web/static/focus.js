"use strict";
// The Focus tab: today's daily note with its `## Focus` lanes on top, from /api/focus (hub-core
// `focus`, the same reader as the hub's Focus tab). `#focus/<target>` opens another note in the
// same view: a day (`daily:2026-11-04`) or a `[[wikilink]]` target (`outbox`, `status/inbox`),
// which the notes CLI resolves and keeps inside the notes. Links in a note are plain `href="#..."`,
// so the browser's Back returns from one. Rendered draws the note; Raw is its markdown, to copy.
// Add to outbox sends one line through POST /api/outbox (`notes outbox add`); the triager files it.

const fcs = { data: null, err: null, raw: false, open: {}, copied: false, draft: "", sending: false, said: null };

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
  if (st.tab === "focus") renderFocus();
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

function sectionFold(s, open) {
  const k = "sec:" + (s.title || "top");
  seed(k, open);
  return cfold(k, `<b>${esc(s.title || "Top")}</b>`, `<div class="md">${md(s.markdown, { notes: true })}</div>`, fcs.open);
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
  ].join("");
  const seg = `<div class="seg"><button data-f="rendered"${fcs.raw ? "" : ` class="on"`}>Rendered</button><button data-f="raw"${fcs.raw ? ` class="on"` : ""}>Raw</button></div>`;
  return `<div class="bhead"><span>FOCUS ${day}${counts}</span><span class="opts">${nav}${seg}</span></div>`;
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
    if (!f && !s.title) html += `<div class="md">${md(s.markdown, { notes: true })}</div>`;
    else html += sectionFold(s, !f);
  }
  if (!html) html = `<div class="empty">This note is empty.</div>`;
  html += outboxBox();
  const links = n.links || [];
  if (links.length) {
    html += `<h2 class="sec">Links in this note</h2><div class="opts">${links.map((l) =>
      `<a class="wl${l.exists ? "" : " missing"}" href="${focusHref(l.target)}" title="${esc(l.target)}${l.exists ? "" : " (no such note)"}">${esc(l.label || l.target)}</a>`).join("")}</div>`;
  }
  return html;
}

function outboxBox() {
  const s = fcs.said;
  const said = !s ? "" : s.ok
    ? `<div class="muted">Sent "${esc(s.text)}". The triager files it from the <a class="wl" href="${focusHref("outbox")}">outbox</a>.</div>`
    : `<div class="err">${esc(s.text)}</div>`;
  return `<h2 class="sec">Add to outbox</h2><div class="opts">` +
    `<input id="f-out" placeholder="one line; the triager files it" value="${esc(fcs.draft)}">` +
    `<button class="btn sm primary" data-f="send"${fcs.sending ? " disabled" : ""}>${fcs.sending ? "Sending..." : "Send"}</button></div>${said}`;
}

async function sendOutbox() {
  const text = fcs.draft.trim();
  if (!text || fcs.sending) return;
  fcs.sending = true; renderFocus();
  try { await post("/api/outbox", { text }); fcs.draft = ""; fcs.said = { ok: true, text }; }
  catch (e) { fcs.said = { ok: false, text: e.message }; }
  fcs.sending = false; renderFocus();
  if (fcs.said.ok && focusTarget() === "outbox") refreshFocus();
}

function renderFocus() {
  const el = $("focus");
  const v = fcs.data;
  if (!v) { el.innerHTML = `<div class="empty">${fcs.err ? esc(fcs.err) : "Reading the note..."}</div>`; return; }
  let html = focusHead(v);
  if (fcs.err) html += `<div class="panel down">${esc(fcs.err)}</div>`;
  // A re-read while the line is being typed keeps the cursor in it.
  const typing = document.activeElement && document.activeElement.id === "f-out" ? document.activeElement.selectionStart : null;
  paint(el, html + focusBody(v), fcs.open);
  const i = typing == null ? null : $("f-out");
  if (i) { i.focus(); i.setSelectionRange(typing, typing); }
}

$("focus").addEventListener("click", (e) => {
  const b = e.target.closest("[data-f]");
  if (!b) return;
  const f = b.dataset.f;
  if (f === "back") history.back();
  else if (f === "refresh") refreshFocus();
  else if (f === "send") sendOutbox();
  else if (f === "rendered" || f === "raw") { fcs.raw = f === "raw"; fcs.copied = false; renderFocus(); }
  else if (f === "copy" && fcs.data) {
    navigator.clipboard.writeText(fcs.data.note.markdown).then(() => { fcs.copied = true; renderFocus(); }, (err) => { fcs.err = "copy: " + err.message; renderFocus(); });
  }
});
$("focus").addEventListener("input", (e) => { if (e.target.id === "f-out") fcs.draft = e.target.value; });
$("focus").addEventListener("keydown", (e) => { if (e.target.id === "f-out" && e.key === "Enter") sendOutbox(); });
$("focus").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) fcs.open[e.target.dataset.k] = e.target.open;
}, true);

// Nothing watches ~/.notes (dashboards.md rule 9 is open on it), so the tab reads on every show,
// which a note link or a day button is too, and on Refresh.
TABS.focus = {
  show() {
    // A different note than the one drawn starts from its own top.
    if (fcs.data && fcs.data.note.target !== focusTarget().split(/[|#]/)[0].trim()) { fcs.data = null; fcs.copied = false; $("focus").scrollTop = 0; }
    renderFocus(); refreshFocus();
  },
  onEvent(ev) { if (st.tab === "focus" && ev.kind === "resync") refreshFocus(); },
};
