"use strict";
// Small charts for the board tabs: plain SVG and HTML, coloured from the page's CSS tokens so
// both themes work. Each returns an HTML string; the tab puts it into the page.

// fleet-sessions buckets, most urgent first (its `rank`).
const BUCKETS = ["NEEDS", "STALLED", "LANDED", "UNCLEAR", "WORKING", "DONE"];
const bucketColor = (b) => `var(--b-${BUCKETS.includes(b) ? b.toLowerCase() : "unclear"})`;

// A horizontal meter: frac in [0, 1].
function meter(frac, color) {
  const pct = Math.max(0, Math.min(1, frac || 0)) * 100;
  return `<span class="meter"><span style="width:${pct.toFixed(1)}%;background:${color || "var(--accent)"}"></span></span>`;
}

// "3m", "2h 5m", "4d 3h".
function dur(min) {
  if (min == null || isNaN(min)) return "-";
  min = Math.round(min);
  if (min < 60) return `${min}m`;
  if (min < 1440) return `${Math.floor(min / 60)}h${min % 60 ? " " + (min % 60) + "m" : ""}`;
  return `${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`;
}

// Long targets keep the tail that tells them apart, cut at a dash:
// "unity-core-playground-agent-26:1" -> "unity-..agent-26:1".
function clip(s, n = 24) {
  if (s.length <= n) return s;
  let tail = s.slice(-(n - 8));
  const cut = tail.indexOf("-");
  if (cut > 0 && cut < tail.length - 4) tail = tail.slice(cut + 1);
  return s.slice(0, 6) + ".." + tail;
}

// A colour key: [[label, color], ...].
const legend = (items) => `<span class="legend">${items.map(([l, c]) => `<span><i style="background:${c}"></i>${esc(l)}</span>`).join("")}</span>`;

const kfmt = (n) => (n == null ? "-" : n >= 1e9 ? (n / 1e9).toFixed(1) + "B" : n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? Math.round(n / 1e3) + "k" : String(n));

// Swimlanes over [t0, t1] (ms). lanes: [{label, sub, dim, segs: [{a, b, key, title}]}], where
// colorOf(key) picks a segment's fill. Each lane's bar is an SVG stretched to the column, so it
// fills any width; hour ticks sit under the last lane.
function swimlanes(lanes, t0, t1, colorOf) {
  const span = t1 - t0, x = (t) => (((t - t0) / span) * 100).toFixed(3);
  const rows = lanes.map((l) => {
    const rects = l.segs.map((s) => `<rect x="${x(s.a)}" y="0" width="${Math.max(0.15, ((s.b - s.a) / span) * 100).toFixed(3)}" height="1" fill="${colorOf(s.key)}"><title>${esc(s.title || s.key)}</title></rect>`).join("");
    return `<div class="lane${l.dim ? " dim" : ""}"><span class="ll" title="${esc(l.label)}">${esc(clip(l.label))}${l.sub ? ` <i>${esc(l.sub)}</i>` : ""}</span><svg viewBox="0 0 100 1" preserveAspectRatio="none">${rects}</svg></div>`;
  }).join("");
  const ticks = [];
  const step = span > 36 * 3600e3 ? 6 * 3600e3 : span > 12 * 3600e3 ? 3 * 3600e3 : 3600e3;
  const first = new Date(t0); first.setMinutes(0, 0, 0);
  for (let t = first.getTime() + step; t < t1; t += step) {
    const d = new Date(t);
    ticks.push(`<span style="left:${x(t)}%">${String(d.getHours()).padStart(2, "0")}:00</span>`);
  }
  return `<div class="lanes">${rows}<div class="lane axis"><span class="ll"></span><div class="ticks">${ticks.join("")}</div></div></div>`;
}

// Categorical series in fixed order (the dataviz palette: --c1..--c4 in both themes); anything
// past the slots folds into "Other", never a generated hue.
const SLOTS = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)"];
const OTHER = "var(--c-other)";

const usd = (n) => (n == null ? "-" : "$" + (n >= 100 ? Math.round(n).toLocaleString() : n.toFixed(2)));

// A column chart on one axis. cols: [{key, label, tip, segs: [{v, color}]}], stacked bottom up.
// Each column carries data-key (for clicks) and data-tip (the shared hover tooltip); `sel` marks
// one column. HTML columns rather than a stretched SVG, so the rounded caps keep their shape.
function columns(cols, { height = 140, sel = null, yfmt = String } = {}) {
  const max = Math.max(1, ...cols.map((c) => c.segs.reduce((a, s) => a + (s.v || 0), 0)));
  const grid = [max, max / 2].map((v) => `<div class="cg" style="bottom:${(v / max) * 100}%"><span>${esc(yfmt(Math.round(v * 100) / 100))}</span></div>`).join("");
  const body = cols.map((c) => {
    const segs = c.segs.filter((s) => s.v > 0).map((s) => `<i style="height:${(s.v / max) * 100}%;background:${s.color}"></i>`).join("");
    return `<div class="cc${c.key === sel ? " sel" : ""}" data-key="${esc(c.key)}" data-tip="${esc(c.tip)}"><div class="cs">${segs}</div><span class="cx">${esc(c.label || "")}</span></div>`;
  }).join("");
  return `<div class="cols" style="--h:${height}px"><div class="cplot">${grid}<div class="cbars">${body}</div></div></div>`;
}

// One tooltip for every [data-tip] mark on the page; the text is plain, newlines kept.
(() => {
  const tip = document.createElement("div");
  tip.className = "tip";
  tip.hidden = true;
  document.body.appendChild(tip);
  document.addEventListener("mousemove", (e) => {
    const m = e.target.closest && e.target.closest("[data-tip]");
    if (!m || !m.dataset.tip) { tip.hidden = true; return; }
    tip.textContent = m.dataset.tip;
    tip.hidden = false;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    tip.style.left = Math.min(e.clientX + 12, innerWidth - w - 8) + "px";
    tip.style.top = (e.clientY - h - 12 < 4 ? e.clientY + 16 : e.clientY - h - 12) + "px";
  });
})();
