"use strict";
// What every tab shares: fetch helpers, the refetch coalescer, the formatters, the keep-your-place
// render, and when a tab re-reads (poll, pushed). Loaded first; app.js and the tab files
// (static/*.js) only use these, never each other's copies. poll and pushed read app.js's `st`
// and `behind` when called, by which time every script has loaded.

const $ = (id) => document.getElementById(id);
const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

async function api(path, opts) {
  const r = await fetch(path, Object.assign({ credentials: "same-origin" }, opts));
  if (r.status === 401) { location.reload(); throw new Error("Signed out. Reloading to sign in again."); }
  if (!r.ok) {
    // What failed first, then the server's own words, then what to do (comms-standard, UI text).
    const what = path.replace(/^\/api\//, "").split(/[/?]/)[0] || "the page";
    const said = ((await r.text()) || r.statusText).trim().slice(0, 300);
    const verb = opts && opts.method && opts.method !== "GET" ? "send to" : "read";
    throw new Error(`Could not ${verb} ${what} (HTTP ${r.status})${said ? ": " + said : ""}. Retry, or check the agent-web log.`);
  }
  return r.status === 204 ? null : (r.headers.get("content-type") || "").includes("json") ? r.json() : r.text();
}
const post = (path, body) => api(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

// Run fn, and if it is asked for again while running, run it once more after.
// An event storm becomes at most one trailing refetch, with no timer involved.
function coalesce(fn) {
  let running = false, again = false;
  return async function run() {
    if (running) { again = true; return; }
    running = true;
    try { await fn(); } catch (e) { console.warn(e); }
    running = false;
    if (again) { again = false; run(); }
  };
}

// Epoch milliseconds as HH:MM local time.
const clock = (ms) => { const d = new Date(ms); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
// A time (epoch seconds, or an ISO string) as HH:MM today, with its weekday otherwise.
function when(t) {
  if (!t) return "-";
  const d = new Date(typeof t === "number" ? t * 1e3 : t);
  if (isNaN(d)) return esc(t);
  return d.toDateString() === new Date().toDateString() ? clock(d.getTime())
    : d.toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" });
}
// A time (epoch seconds, or an ISO string) as epoch milliseconds, NaN when it is neither.
const tms = (t) => new Date(typeof t === "number" ? t * 1e3 : t).getTime();
// A time as HH:MM today, "Tue 3 Nov HH:MM" on another day.
function stamp(t) {
  const m = tms(t);
  if (!t || isNaN(m)) return t ? esc(t) : "-";
  const d = new Date(m);
  if (d.toDateString() === new Date().toDateString()) return clock(m);
  return `${d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })} ${clock(m)}`;
}
// Minutes as one coarse unit, for an age: "5m", "3h", "2d".
function ageMin(min) {
  if (min == null || isNaN(min)) return "";
  min = Math.max(0, Math.round(min));
  return min < 60 ? `${min}m` : min < 2880 ? `${Math.round(min / 60)}h` : `${Math.round(min / 1440)}d`;
}
// How long ago a time was, as ageMin words.
const ago = (t) => ageMin((Date.now() - tms(t)) / 60000);
// "3m", "2h 5m", "4d 3h".
function dur(min) {
  if (min == null || isNaN(min)) return "-";
  min = Math.round(min);
  if (min < 60) return `${min}m`;
  if (min < 1440) return `${Math.floor(min / 60)}h${min % 60 ? " " + (min % 60) + "m" : ""}`;
  return `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`;
}

// The total of an object's numeric values (a missing object or value counts 0).
const sumOf = (o) => Object.values(o || {}).reduce((a, v) => a + (v || 0), 0);
const pct = (v) => (v == null ? "-" : Math.round(v * 100) + "%");
const secs = (s) => (s == null || !(s > 0) ? "-" : s < 60 ? Math.round(s) + "s" : dur(s / 60));
// A headline number with its label, coloured by --c.
const tile = (l, v, c, sub) => `<div class="tile" style="--c:${c}"><span class="tl">${l}</span><span class="tv">${v}</span>${sub ? `<span class="ts1">${sub}</span>` : ""}</div>`;

// Card pieces for the tabs whose rows are cards (Queue, Waiting): a title row with chips, one
// quiet line, then folds for what the human rarely needs. Every argument named html is already
// escaped; text arguments are escaped here.
// A small label tinted by cls: waiting, running, ok, bad, or prio with urgent or high.
const cchip = (cls, html, tip) => `<span class="cchip ${cls}"${tip ? ` title="${esc(tip)}"` : ""}>${html}</span>`;
// The card's title (text) and its chips (html); tip is the title's tooltip.
const cardHead = (title, chips, tip) =>
  `<div class="chead"><span class="ctitle"${tip ? ` title="${esc(tip)}"` : ""}>${esc(title)}</span>${chips.join("")}</div>`;
// One quiet line from the parts (html) that are there.
function cardLine(parts) {
  const p = parts.filter(Boolean);
  return p.length ? `<div class="cline">${p.join(", ")}</div>` : "";
}
// A fold keyed by k, open when open[k] says so (paint or a toggle listener keeps open current).
const cfold = (k, summary, inner, open) =>
  `<details class="cfold" data-k="${esc(k)}"${open && open[k] ? " open" : ""}><summary>${summary}</summary>${inner}</details>`;
// The facts (text) that have a value, as a name/value grid for a fold.
function facts(rows) {
  const r = rows.filter(([, v]) => v);
  return r.length ? `<dl>${r.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>` : "";
}
// A session's estimate from its plan phases (fleet-bench through fleet-sessions): "ETA 14:30",
// or "overdue 2h" once it has passed. Empty without one.
function etaText(p) {
  if (!p || !p.eta_epoch) return "";
  const late = (Date.now() / 1000 - p.eta_epoch) / 60;
  return late > 0
    ? `<span class="qlate" title="estimate ${esc(p.eta || "")}">overdue ${ageMin(late)} (ETA was ${stamp(p.eta_epoch)})</span>`
    : `<span title="estimate ${esc(p.eta || "")}">ETA ${stamp(p.eta_epoch)}</span>`;
}
// Redraw answer cards (sel matches them) without eating a reply being typed into one: the
// card is found again by its session target or ask id, and the text and focus go back.
function keepTyping(sel, draw) {
  const f = document.activeElement, card = f && f.closest && f.closest(sel);
  const keep = card && f.matches("[data-free]") ? { k: card.dataset.t || card.dataset.id, v: f.value } : null;
  draw();
  if (!keep) return;
  const again = [...document.querySelectorAll(sel)].find((c) => (c.dataset.t || c.dataset.id) === keep.k);
  const input = again && again.querySelector("[data-free]");
  if (input) { input.value = keep.v; input.focus(); }
}

// Follow a scrolling log: is the reader at its end, and put them there.
const atBottom = (el) => el.scrollHeight - el.scrollTop - el.clientHeight < 40;
const toBottom = (el) => { el.scrollTop = el.scrollHeight; };

// Replace a board's HTML without moving the reader: the scroll position and which folds are
// open survive (each <details data-k> is remembered in `open`, when given).
function paint(el, html, open) {
  const y = el.scrollTop;
  if (open) el.querySelectorAll("details[data-k]").forEach((d) => { open[d.dataset.k] = d.open; });
  el.innerHTML = html;
  el.scrollTop = y;
}

// A tab whose source pushes nothing (Prometheus, journald) re-reads on a timer while it is
// the open tab and the page is visible. A tick that falls while the page is hidden marks it
// behind, so the resync on coming back (app.js) reads it once; the tab's onEvent must refresh
// on "resync". One interval per tab, cleared as soon as the tab is left; `ms` is the source's
// own cadence. Returns the tab's show(): read now, then keep reading.
function poll(tab, refresh, ms) {
  let timer = null;
  const tick = () => {
    if (st.tab !== tab) { clearInterval(timer); timer = null; return; }
    if (document.hidden) behind = true; else refresh();
  };
  return () => { refresh(); if (!timer) timer = setInterval(tick, ms); };
}

// A tab whose source pushes file events re-reads on them (`kinds`, plus resync) only while it
// is open; one that changed while closed is read once, the next time it is shown. show(force)
// also reads when the tab has nothing yet, so a failed first read is retried on the next visit.
// A folded Log section lists at most this many rows, then says how many older ones it left out.
const LOG_ROWS = 50;
const older = (n) => (n > 0 ? `<div class="muted more">+${n} older</div>` : "");

function pushed(tab, kinds, refresh) {
  let stale = true;
  return {
    show(force) { if (stale || force) { stale = false; refresh(); } },
    onEvent(ev) {
      if (ev.kind !== "resync" && !kinds.includes(ev.kind)) return;
      if (st.tab === tab) refresh(); else stale = true;
    },
  };
}
