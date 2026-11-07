"use strict";
// The shared data table (docs/dashboards.md rule 7). The server applies hub_core::table and
// sends its summary beside the rows (`table`: the query, each state chip's count, each
// header's sort and the sort a click on it gives, each dropdown's values and the query that
// picks one). This file only draws that and turns a click or a keystroke into the view keys
// the server reads; what a query means is decided in hub-core alone.

// The view keys, in the tab's URL query (`#infra?q=source:ci&s=failed&sort=started&dir=asc`)
// and in the API's, so a filtered view is a link. A tab's second table names its keys with a
// prefix (`pre`, Home's Needs you: nq, ns, nsort, ndir), the same in the URL and the API.
const TBL_KEYS = ["q", "s", "sort", "dir"];

// One table's view keys of a tab's URL query, as the API's query string.
function tblParams(query, pre = "") {
  const p = new URLSearchParams(query || ""), out = new URLSearchParams();
  for (const k of TBL_KEYS.map((k) => pre + k)) if (p.get(k)) out.set(k, p.get(k));
  return out;
}

// The URL query with the patch (tblPatch's plain keys) applied to one table's keys; a blank value
// drops its key, so the plain view is bare.
function tblSet(query, patch, pre = "") {
  const p = new URLSearchParams(query || "");
  for (const [k, v] of Object.entries(patch)) { if (v) p.set(pre + k, v); else p.delete(pre + k); }
  return p.toString();
}

// Which of a tab's tables an event came from: the `data-tbl` (its key prefix) of the block
// holding its bar and rows, "" outside one, so one delegated listener sends each patch to its own view.
const tblOf = (e) => e.target?.closest?.("[data-tbl]")?.dataset.tbl || "";

// One dropdown per facet, each option the whole query that picks its value.
const tblFacets = (t) => t.facets.map((f) => `<select data-tq title="${esc(f.key)}"><option value="${esc(f.clear)}">every ${esc(f.key)}</option>` +
  f.values.map((v) => `<option value="${esc(v.q)}"${v.value === f.on ? " selected" : ""}>${esc(v.value)} (${v.n})</option>`).join("") + `</select>`).join("");
// One count chip, here and on the tabs that still filter their own lists.
const chipBtn = (on, attr, val, label, n) =>
  `<button class="${on ? "on" : ""}" ${attr}="${esc(val)}">${esc(label)} <span class="n">${n}</span></button>`;
// The state chips with their counts; the first keeps every row.
const tblChips = (t) => t.states.map((c, i) => chipBtn(i ? c.name === t.state : !t.state, "data-ts", i ? c.name : "", c.name, c.n)).join("");

// A refresh must not take the search box or an open dropdown from under the human: with focus
// in the bar only what is around the control repaints. False when focus is elsewhere.
function tblRepaint(id, t, body) {
  const f = document.activeElement;
  if (f?.id !== id + "-q" && (f?.dataset?.tq === undefined || !f.closest?.(`#${id}-facets`))) return false;
  if (f.id === id + "-q") paint($(id + "-facets"), tblFacets(t));
  paint($(id + "-chips"), tblChips(t));
  paint($(id + "-body"), body());
  return true;
}

// The same parts repainted with focus elsewhere: the dropdowns too, with their new counts.
function tblRedraw(id, t, body) {
  if ($(id + "-facets")) paint($(id + "-facets"), tblFacets(t));
  if ($(id + "-chips")) paint($(id + "-chips"), tblChips(t));
  paint($(id + "-body"), body());
}

// A picked dropdown lets go of focus, so the answer redraws it with the new counts. `onView`
// gets the event too, for a tab with two tables (tblOf).
function tblListen(el, onView) {
  for (const ev of ["input", "change"]) el.addEventListener(ev, (e) => {
    const v = tblPatch(e);
    if (!v) return;
    if (e.type === "change" && e.target.dataset.tq !== undefined) e.target.blur?.();
    onView(v, e);
  });
}

// The search box, the dropdowns and the chips. `id` names the parts a repaint while the search
// box has focus replaces around it: `<id>-facets` and `<id>-chips`. A tab whose overview tiles are
// its chips (Sessions) passes `chips` false.
function tblBar(id, t, hint, chips = true) {
  return `<div class="card bfilter qcfilter"><div class="opts"><input id="${id}-q" data-tsearch placeholder="${esc(hint)}" value="${esc(t.q)}" title="key:value matches a column, a repeated key is any of them, -key:value excludes, a word searches the text">` +
    `<span id="${id}-facets">${tblFacets(t)}</span></div></div>` + (chips ? `<div class="seg fseg" id="${id}-chips">${tblChips(t)}</div>` : "");
}

// The header row. `labels` maps a column key to [text, class]; a column it leaves out is not drawn.
// `pre` names the data attributes a click reads (`data-<pre>sort`, `data-<pre>dir`): a second table
// on a tab sorts apart from the first by naming its own.
function tblHead(t, labels, pre = "t") {
  return "<tr>" + t.columns.filter((c) => labels[c.key]).map((c) => {
    const [label, cls] = labels[c.key];
    const aria = c.sort ? ` aria-sort="${c.sort === "asc" ? "ascending" : "descending"}"` : "";
    const mark = c.sort ? (c.sort === "asc" ? " ^" : " v") : "";
    return `<th${cls ? ` class="${cls}"` : ""}${aria}><button class="thsort" data-${pre}sort="${esc(c.next_sort)}" data-${pre}dir="${c.next_dir}" title="sort by ${esc(label)}">${esc(label)}${mark}</button></th>`;
  }).join("") + "</tr>";
}

// The button a capped body ends in; the view's own click listener answers `data-all`.
const tblMore = (n, word = "older") => (n > 0 ? `<button class="btn sm" data-all="1">+${n} ${word}</button>` : "");

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
