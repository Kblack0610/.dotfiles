"use strict";
// The shared data table (docs/dashboards.md rule 7). The server applies hub_core::table and
// sends its summary beside the rows (`table`: the query, each state chip's count, each
// header's sort and the sort a click on it gives, each dropdown's values and the query that
// picks one). This file only draws that and turns a click or a keystroke into the view keys
// the server reads; what a query means is decided in hub-core alone.

// The view keys, in the tab's URL query (`#infra?q=source:ci&s=failed&sort=started&dir=asc`)
// and in the API's, so a filtered view is a link.
const TBL_KEYS = ["q", "s", "sort", "dir"];

// The view keys of a tab's URL query, as the API's query string.
function tblParams(query) {
  const p = new URLSearchParams(query || ""), out = new URLSearchParams();
  for (const k of TBL_KEYS) if (p.get(k)) out.set(k, p.get(k));
  return out;
}

// The URL query with the patch applied; a blank value drops its key, so the plain view is bare.
function tblSet(query, patch) {
  const p = new URLSearchParams(query || "");
  for (const [k, v] of Object.entries(patch)) { if (v) p.set(k, v); else p.delete(k); }
  return p.toString();
}

// One dropdown per facet, each option the whole query that picks its value.
const tblFacets = (t) => t.facets.map((f) => `<select data-tq title="${esc(f.key)}"><option value="${esc(f.clear)}">every ${esc(f.key)}</option>` +
  f.values.map((v) => `<option value="${esc(v.q)}"${v.value === f.on ? " selected" : ""}>${esc(v.value)} (${v.n})</option>`).join("") + `</select>`).join("");
// One count chip, here and on the tabs that still filter their own lists.
const chipBtn = (on, attr, val, label, n) =>
  `<button class="${on ? "on" : ""}" ${attr}="${esc(val)}">${esc(label)} <span class="n">${n}</span></button>`;
// The state chips with their counts; the first keeps every row.
const tblChips = (t) => t.states.map((c, i) => chipBtn(i ? c.name === t.state : !t.state, "data-ts", i ? c.name : "", c.name, c.n)).join("");

// The search box, the dropdowns and the chips. `id` names the parts tblPaint replaces around a
// control in use: `<id>-facets` and `<id>-chips`.
function tblBar(id, t, hint) {
  return `<div class="card bfilter qcfilter"><div class="opts"><input id="${id}-q" data-tsearch placeholder="${esc(hint)}" value="${esc(t.q)}" title="key:value matches a column, a repeated key is any of them, -key:value excludes, a word searches the text">` +
    `<span id="${id}-facets">${tblFacets(t)}</span></div></div><div class="seg fseg" id="${id}-chips">${tblChips(t)}</div>`;
}

// Draw a table view. `parts` is its regions' html in order, each in an `<id>-<part>` element:
// `head` above the bar, the rest below it. A refresh must not take the search box or an open
// dropdown from under the human, so while one has focus everything around it repaints and it stays.
function tblPaint(el, id, t, hint, parts) {
  const f = document.activeElement, region = ([k, html]) => `<div id="${id}-${k}">${html}</div>`;
  if (f && el.contains(f) && (f.id === `${id}-q` || f.dataset.tq !== undefined)) {
    if (f.id === `${id}-q`) paint($(`${id}-facets`), tblFacets(t));
    paint($(`${id}-chips`), tblChips(t));
    for (const [k, html] of Object.entries(parts)) paint($(`${id}-${k}`), html);
    return;
  }
  const { head, ...rest } = parts;
  paint(el, region(["head", head]) + tblBar(id, t, hint) + Object.entries(rest).map(region).join(""));
}

// The header row. `labels` maps a column key to [text, class]; a column it leaves out is not drawn.
function tblHead(t, labels) {
  return "<tr>" + t.columns.filter((c) => labels[c.key]).map((c) => {
    const [label, cls] = labels[c.key];
    const aria = c.sort ? ` aria-sort="${c.sort === "asc" ? "ascending" : "descending"}"` : "";
    const mark = c.sort ? (c.sort === "asc" ? " ^" : " v") : "";
    return `<th${cls ? ` class="${cls}"` : ""}${aria}><button class="thsort" data-tsort="${esc(c.next_sort)}" data-tdir="${c.next_dir}" title="sort by ${esc(label)}">${esc(label)}${mark}</button></th>`;
  }).join("") + "</tr>";
}

// The button a capped body ends in; the view's own click listener answers `data-all`.
const tblMore = (n) => (n > 0 ? `<button class="btn sm" data-all="1">+${n} older</button>` : "");

// The view patch an event on the bar or a header asks for, or null when it is not one of theirs.
function tblPatch(e) {
  const t = e.target;
  if (!t || !t.dataset) return null;
  if (e.type === "input" && t.dataset.tsearch != null) return { q: t.value };
  if (e.type === "change" && t.dataset.tq != null) return { q: t.value };
  if (e.type !== "click" || !t.closest) return null;
  const sort = t.closest("[data-tsort]");
  if (sort) return { sort: sort.dataset.tsort, dir: sort.dataset.tsort && sort.dataset.tdir === "asc" ? "asc" : "" };
  const chip = t.closest("[data-ts]");
  if (chip) return { s: chip.dataset.ts };
  return null;
}

// Send every view change in `el` to `view(patch)`. A picked dropdown lets go of focus, so the
// answer redraws it with the new counts.
function tblBind(el, view) {
  for (const ev of ["click", "input", "change"]) el.addEventListener(ev, (e) => {
    const v = tblPatch(e);
    if (!v) return;
    if (e.type === "change" && e.target.dataset.tq !== undefined) e.target.blur?.();
    view(v);
  });
}
