"use strict";
// The card hub_core::cards::Card words, drawn the way Home's grid draws it. Needs ui.js's esc and
// NO_DATA.

// One card per tab, as hub_core::cards words it: the big number in the card's hue, the bar of
// its counted states, the labelled counts and its headed lists of rows. The title and the arrow open
// the tab; a count opens the rows it counts, and a look-first row its record, when it has one.
const HUE = { ok: "ok", warn: "warn", red: "bad", nodata: "" };
const LEVEL = { ok: "ok", warn: "needs a look", red: "broken", nodata: NO_DATA };
function cardHtml(c) {
  const to = esc(c.link), hue = HUE[c.level];
  const total = c.bar.reduce((n, s) => n + s.n, 0);
  const bar = total ? c.bar.map((s) => `<i class="${HUE[s.level]}" style="flex:${s.n}"></i>`).join("") : "<i></i>";
  const parts = c.parts.map((p) => `<a class="kp" href="${p.link ? esc(p.link) : to}"><span>${esc(p.label)}</span><b class="${HUE[p.level]}">${esc(p.value)}</b></a>`).join("");
  const row = (f) => `<a class="kf" href="${esc(f.link || c.link)}"><span><b>${esc(f.text)}</b>${f.sub ? `<small>${esc(f.sub)}</small>` : ""}</span>${f.level !== "ok" ? `<em class="${HUE[f.level]}">${LEVEL[f.level]}</em>` : ""}</a>`;
  const lists = c.lists.filter((l) => l.rows.length).map((l) => `<div class="kl"><div class="kfh">${esc(l.head)}</div>${l.rows.map(row).join("")}</div>`).join("");
  return `<section class="kcard" data-card="${esc(c.tab)}">` +
    `<a class="kt" href="${to}" title="${esc(c.counted)}">${esc(c.title)}<span aria-hidden="true">-&gt;</span></a>` +
    `<div class="kbig ${hue}">${esc(c.big)}<span class="ku">${esc(c.unit)}</span></div>` +
    `<div class="kbar" title="${esc(LEVEL[c.level])}">${bar}</div>` +
    (parts ? `<div class="kparts">${parts}</div>` : "") +
    (c.error ? `<div class="cline warn">${esc(c.error)}</div>` : "") +
    lists + "</section>";
}

// Home's grid packed (app.css .kgrid.packed): each card spans its own height plus the column gap in
// 1px rows, so it starts one gap under the card above it, not under the tallest card of a row.
// One observer for the grid on screen; it respans a card whenever its height changes, a width
// change that rewraps it included, and its first answer comes before the first paint.
let cardPacker = null;
function packCards(root) {
  if (typeof ResizeObserver !== "function") return;
  const grid = root.querySelector(".kgrid");
  cardPacker?.disconnect();
  if (!grid) return;
  cardPacker = new ResizeObserver((seen) => {
    const gap = parseFloat(getComputedStyle(grid).columnGap) || 0;
    for (const e of seen) e.target.style.gridRowEnd = `span ${Math.ceil(e.borderBoxSize[0].blockSize + gap)}`;
  });
  for (const c of grid.querySelectorAll(".kcard")) cardPacker.observe(c);
  grid.classList.add("packed");
}
