"use strict";
// The outbox view, Daily's `#daily/outbox` (focus.js shows it in the note's place): the outbox as
// a doc you type into, and what intake did with its lines today. GET /api/outbox is hub_core::outbox (the hub TUI's reader); PUT /api/outbox
// {base, text} is `notes outbox put --base`, a compare-and-swap on the items' hash. The triager
// sweeps 30s after the last save and takes the lines it files out of the doc, so the page and the
// sweep both write it: every write names the hash it started from, and a 409 hands back the
// current doc, which is merged line by line (mergeLines) before saving again.
//
// The line under the cursor is held back (outgoing) until Enter or leaving the box, so a sweep
// never files half a sentence. Reads and writes run one at a time through `sync`.

// The idle wait before a save: a UI debounce, not a poll. Each save restarts the sweep's 30s.
const OUTBOX_SAVE_IDLE_MS = 1500;

const obx = { view: null, base: "", baseText: "", err: null, savedAt: null, held: false, wantRead: true, timer: null, built: false };

const norm = (s) => {
  const ls = String(s || "").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (ls.length && !ls[0]) ls.shift();
  while (ls.length && !ls[ls.length - 1]) ls.pop();
  return ls;
};

// The lines of a not matched one for one in b, in a's order.
function minus(a, b) {
  const left = new Map();
  for (const l of b) left.set(l, (left.get(l) || 0) + 1);
  return a.filter((l) => {
    const n = left.get(l) || 0;
    if (n) left.set(l, n - 1);
    return !n;
  });
}

// mine, less what the other writer took since base, plus what it added; at[i] is where mine's
// line i went (-1 if it was taken). A line typed since base is never in base, so it is never taken.
function mergeLines(base, theirs, mine) {
  const taken = new Map();
  for (const l of minus(base, theirs)) taken.set(l, (taken.get(l) || 0) + 1);
  const lines = [], at = [];
  for (const l of mine) {
    const n = taken.get(l) || 0;
    if (n) { taken.set(l, n - 1); at.push(-1); } else { at.push(lines.length); lines.push(l); }
  }
  for (const l of minus(minus(theirs, base), mine)) lines.push(l);
  return { lines, at };
}

// What a save sends: the box, less the line the cursor is on while it is new and the box has
// focus (held back until Enter or blur). `cursor` is -1 when the box is not focused.
function outgoing(text, cursor, baseLines) {
  const ls = String(text).split("\n");
  if (cursor < 0) return { text: ls.join("\n"), held: false };
  const row = String(text).slice(0, cursor).split("\n").length - 1;
  const l = ls[row].trim();
  if (!l || baseLines.includes(ls[row].replace(/\s+$/, ""))) return { text: ls.join("\n"), held: false };
  ls.splice(row, 1);
  return { text: ls.join("\n"), held: true };
}

const box = () => $("o-doc");
const focused = () => document.activeElement === box();

// Take a doc the server sent: merge it into the box, keeping the cursor on the same line.
function adopt(doc) {
  const b = box();
  const mine = b.value;
  const pos = focused() ? b.selectionStart : -1;
  const m = mergeLines(obx.baseText.split("\n"), doc.text.split("\n"), mine.split("\n"));
  const value = m.lines.join("\n");
  if (value !== mine) {
    b.value = value;
    if (pos >= 0) {
      const before = mine.slice(0, pos).split("\n");
      const row = before.length - 1, col = before[row].length;
      let to = m.at[row];
      if (to < 0) to = Math.max(0, Math.min(row, m.lines.length - 1));
      const at = m.lines.slice(0, to).reduce((n, l) => n + l.length + 1, 0) + Math.min(col, (m.lines[to] || "").length);
      b.setSelectionRange(at, at);
    }
  }
  obx.base = doc.hash;
  obx.baseText = doc.text;
  if (obx.view) obx.view.doc = doc;
}

async function putOutbox(base, text) {
  const r = await fetch("/api/outbox", { method: "PUT", credentials: "same-origin", headers: { "content-type": "application/json" }, body: JSON.stringify({ base, text }) });
  if (r.status === 401) { location.reload(); throw new Error("Signed out. Reloading to sign in again."); }
  if (r.ok || r.status === 409) return { stale: r.status === 409, doc: await r.json() };
  const said = ((await r.text()) || r.statusText).trim().slice(0, 300);
  throw new Error(`Could not save the outbox (HTTP ${r.status})${said ? ": " + said : ""}. Your text is still here; it saves again on the next change.`);
}

// One read or write at a time: a reply from an older state merged after a newer one would bring
// back lines the sweep took.
const sync = coalesce(async () => {
  try {
    if (obx.wantRead || !obx.view) {
      obx.wantRead = false;
      const v = await api("/api/outbox");
      if (!obx.view) { obx.view = v; obx.baseText = v.doc.text; obx.base = v.doc.hash; box().value = v.doc.text; }
      else { obx.view = v; adopt(v.doc); }
      renderHandled();
    }
    // A 409 is the sweep landing between our read and write: merge and go again, at most twice.
    for (let tries = 0; tries < 3; tries++) {
      const out = outgoing(box().value, focused() ? box().selectionStart : -1, norm(obx.baseText));
      obx.held = out.held;
      if (norm(out.text).join("\n") === norm(obx.baseText).join("\n")) break;
      const r = await putOutbox(obx.base, out.text);
      adopt(r.doc);
      if (!r.stale) { obx.savedAt = Date.now(); break; }
    }
    obx.err = null;
  } catch (e) { obx.err = e.message; }
  renderStatus();
});

function soon() {
  clearTimeout(obx.timer);
  obx.timer = setTimeout(sync, OUTBOX_SAVE_IDLE_MS);
}

function statusText() {
  if (obx.err) return `<span class="err">${esc(obx.err)}</span>`;
  const v = obx.view;
  if (!v) return `<span class="muted">Reading the outbox...</span>`;
  const parts = [`${v.doc.waiting} waiting`];
  if (obx.savedAt) parts.push(`saved ${clock(obx.savedAt)}`);
  if (obx.held) parts.push("the line you are on saves on Enter");
  parts.push("the sweep files lines 30s after you stop typing");
  return `<span class="muted">${esc(parts.join(". "))}.</span>`;
}

function handledHtml(v) {
  const head = `<h2 class="sec">Handled today <span class="muted">${esc(v.counts || "")}</span></h2>`;
  if (!v.handled.length) return head + `<div class="muted">Nothing handled yet today.</div>`;
  return head + `<ul class="o-steps">${v.handled.map((s) => {
    const warn = s.action === "left" || s.action === "refused";
    const id = s.id ? " " + s.id : "";
    const to = s.to ? ` in <a class="wl" href="#projects/${encodeURIComponent(s.to)}">${esc(s.to)}</a>` : "";
    const why = s.why ? ` <span class="muted">(why: ${esc(s.why)})</span>` : "";
    return `<li${warn ? ` class="warn"` : ""}><span class="muted">${esc(String(s.ts).slice(11, 16))}</span> ${esc(s.action)}${esc(id)}${to}: ${esc(s.text)}${why}</li>`;
  }).join("")}</ul>`;
}

function renderStatus() { $("o-said").innerHTML = statusText(); }
function renderHandled() { if (obx.view) $("o-handled").innerHTML = handledHtml(obx.view); renderStatus(); }

// Drawn once: a redraw would drop the cursor and the selection out of the box.
function build() {
  if (obx.built) return;
  obx.built = true;
  $("outbox").innerHTML =
    `<div class="dhead"><div class="dtitle"><h2>Outbox</h2></div><div class="opts"><a class="btn sm" href="#daily">Back to Daily</a><a class="btn sm" href="#daily/status/inbox">Inbox</a></div></div>` +
    `<textarea id="o-doc" spellcheck="true" placeholder="One ask per line. Tag #plan to have it planned, #p:project to say where it goes."></textarea>` +
    `<div id="o-said"></div><div id="o-handled"></div>`;
  const b = box();
  b.addEventListener("input", soon);
  b.addEventListener("keydown", (e) => { if (e.key === "Enter") soon(); });
  b.addEventListener("blur", () => { clearTimeout(obx.timer); sync(); });
}

// Not a tab of its own: Daily calls these.
const OUTBOX = {
  show() { build(); obx.wantRead = true; sync(); },
  onEvent(ev) {
    if (ev.kind !== "outbox" && ev.kind !== "resync") return;
    obx.wantRead = true;
    if (st.tab === "daily" && st.arg === "outbox") sync();
  },
};
