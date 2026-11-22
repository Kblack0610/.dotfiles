"use strict";
// web-kit's renderers (README.md): the small set of markup every kblab site draws the same way,
// so a site calls these and never hand-builds a record list, an error block or a fold. A plain
// script with no build and no dependency; it defines one global, `kbUi`, and ui.css styles what
// it draws. Every argument named html is already escaped; every text argument is escaped here.
const kbUi = (() => {
  const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

  // A section head: its title and its count, nothing else. A problem the section holds is a line
  // under the head while it holds, and level (warn, bad) hues the title, so a shut fold still says
  // so; detail is a fold.
  const secHead = (id, title, n, level, tag = "h2") =>
    `<${tag} class="sec${level === "warn" || level === "bad" ? ` ${level}` : ""}"${id ? ` id="sec-${esc(id)}"` : ""}>${esc(title)}` +
    `${n == null || n === "" ? "" : ` <span class="n">${esc(n)}</span>`}</${tag}>`;

  // A fold: the one <details> every page draws. cls is its class; summary and inner are html.
  // k keys it for a page that keeps folds' state (data-k), id anchors it, open is its state, attrs
  // any further attributes (html), sum the summary's (` class="muted fold"`).
  const fold = (cls, summary, inner, o = {}) =>
    `<details${cls ? ` class="${cls}"` : ""}${o.k ? ` data-k="${esc(o.k)}"` : ""}${o.id ? ` id="${esc(o.id)}"` : ""}${o.attrs || ""}${o.open ? " open" : ""}>` +
    `<summary${o.sum || ""}>${summary}</summary>${inner}</details>`;

  // An error block: msg (text) in the error hue. card sizes it as a card, tag "span" draws it
  // inline, id keeps an empty one as a live region, cls adds classes. An empty msg draws the
  // empty block.
  const errPanel = (msg, o = {}) => {
    const tag = o.tag || "div";
    return `<${tag} class="${[o.cls, o.card && "card", "err"].filter(Boolean).join(" ")}"${o.id ? ` id="${esc(o.id)}"` : ""}>${esc(msg || "")}</${tag}>`;
  };

  // A table cell's text at most two lines (ui.md rule 9), the whole of it (full, text) on hover.
  const clamp2 = (html, full) => `<div class="c2" title="${esc(full)}">${html}</div>`;
  // A table cell's text on one line, its second line on hover and in the selected row, the whole on hover.
  const clamp1 = (html, full) => `<div class="c12" title="${esc(full)}">${html}</div>`;
  // A record cell (ui.md rule 9): its name (html; `full` its text) on line one over a muted second
  // line (html; `subFull` its text), each one line cut with an ellipsis and whole on hover, so every
  // row is the same two lines high.
  const rec2 = (html, full, sub, subFull) =>
    `<div class="c1" title="${esc(full)}">${html}</div><div class="c1 muted" title="${esc(subFull)}">${sub || "&nbsp;"}</div>`;

  // A record list as a table: each row is its cells (html), the first the lead, or {cells, cls}
  // for a row that carries a class. Cells are drawn as sent (wrap one in clamp2 or rec2 to cut it),
  // and one renderer means no page hand-builds a <ul> of sentences.
  const tblRec = (rows, cls = "") =>
    `<table class="rec${cls ? ` ${cls}` : ""}">${rows.map((r) => {
      const cells = Array.isArray(r) ? r : r.cells;
      return `<tr${r.cls ? ` class="${r.cls}"` : ""}>${cells.map((c) => `<td>${c}</td>`).join("")}</tr>`;
    }).join("")}</table>`;

  return { esc, secHead, fold, errPanel, clamp2, clamp1, rec2, tblRec };
})();
