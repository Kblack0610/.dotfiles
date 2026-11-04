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
  if (r.status === 401) { location.reload(); throw new Error("unauthorized"); }
  if (!r.ok) throw new Error((await r.text()) || r.statusText);
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
// "3m", "2h 5m", "4d 3h".
function dur(min) {
  if (min == null || isNaN(min)) return "-";
  min = Math.round(min);
  if (min < 60) return `${min}m`;
  if (min < 1440) return `${Math.floor(min / 60)}h${min % 60 ? " " + (min % 60) + "m" : ""}`;
  return `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`;
}

const pct = (v) => (v == null ? "-" : Math.round(v * 100) + "%");
const secs = (s) => (s == null || !(s > 0) ? "-" : s < 60 ? Math.round(s) + "s" : dur(s / 60));
// A headline number with its label, coloured by --c.
const tile = (l, v, c, sub) => `<div class="tile" style="--c:${c}"><span class="tl">${l}</span><span class="tv">${v}</span>${sub ? `<span class="ts1">${sub}</span>` : ""}</div>`;

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
