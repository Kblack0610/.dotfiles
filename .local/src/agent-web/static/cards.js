"use strict";
// The card hub_core::cards::Card words, drawn the way Home's grid draws it. Needs ui.js's esc and
// NO_DATA.

// One card per tab, as hub_core::cards words it: the big number in the card's hue, the bar of
// its counted states, the labelled counts and where to look first. The title and the arrow open
// the tab; a count opens the rows it counts, and a look-first row its record, when it has one.
const HUE = { ok: "ok", warn: "warn", red: "bad", nodata: "" };
const LEVEL = { ok: "ok", warn: "needs a look", red: "broken", nodata: NO_DATA };
function cardHtml(c) {
  const to = esc(c.link), hue = HUE[c.level];
  const total = c.bar.reduce((n, s) => n + s.n, 0);
  const bar = total ? c.bar.map((s) => `<i class="${HUE[s.level]}" style="flex:${s.n}"></i>`).join("") : "<i></i>";
  const parts = c.parts.map((p) => `<a class="kp" href="${p.link ? esc(p.link) : to}"><span>${esc(p.label)}</span><b class="${HUE[p.level]}">${esc(p.value)}</b></a>`).join("");
  const first = c.first.map((f) => `<a class="kf" href="${esc(f.link || c.link)}"><span><b>${esc(f.text)}</b>${f.sub ? `<small>${esc(f.sub)}</small>` : ""}</span>${f.level !== "ok" ? `<em class="${HUE[f.level]}">${LEVEL[f.level]}</em>` : ""}</a>`).join("");
  return `<section class="kcard" data-card="${esc(c.tab)}">` +
    `<a class="kt" href="${to}" title="${esc(c.counted)}">${esc(c.title)}<span aria-hidden="true">-&gt;</span></a>` +
    `<div class="kbig ${hue}">${esc(c.big)}<span class="ku">${esc(c.unit)}</span></div>` +
    `<div class="kbar" title="${esc(LEVEL[c.level])}">${bar}</div>` +
    (parts ? `<div class="kparts">${parts}</div>` : "") +
    (c.error ? `<div class="cline warn">${esc(c.error)}</div>` : "") +
    (first ? `<div class="kfh">${esc(c.first_head)}</div>${first}` : "") + "</section>";
}
