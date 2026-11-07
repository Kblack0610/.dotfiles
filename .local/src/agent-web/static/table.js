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

// The button a capped body ends in; tblTab's listener answers `data-all` (t.all, reset by a view change).
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

// One table of a tab on the shared table, the skeleton every such tab draws with. `o` names:
//   tab    the tab whose URL query (st.views[tab]) holds the view; it is drawn only while open
//   id     the parts' prefix: `<id>-head`, the bar's `<id>-q`, `-facets` and `-chips`, `<id>-body`, `<id>-tail`
//   el     the id of the element it draws into (id), and `on` the one its listener sits on (el);
//          scroller: the scrolling parent whose scrollTop a whole draw keeps
//   pre    the view keys' prefix (tblParams), for a tab's second table; its block carries data-tbl
//   api    the path read with the view keys, plus what params(p, t) adds; with no api the tab reads
//          itself and `refresh` is that read
//   hint   the search box's placeholder; wait: what shows before the first read; chips: false
//          for a tab whose overview tiles are its chips
//   head, body, tail (t)  the html above the bar, the rows and below them; table(t): the summary
//          (data.table); shown(): whether it is on screen (the tab is open)
//   got(t) after a good read; after(t): after every read, once drawn; reset(t): on a view change
//   open() the fold map paint keeps (ui.js); draw(html): the whole paint, when it is more than paint(el, html);
//          render(): the tab's own, for a table drawn inside a tab that draws itself (Home)
//   state  the tab's own fields, kept beside data, err, sel and all on the object this returns, which
//          also carries refresh(), render(), view(patch), repaint(), redraw() and html().
function tblTab(o) {
  const t = Object.assign({ data: null, err: null, sel: null, all: false }, o.state), id = o.id, pre = o.pre || "", elId = o.el || id;
  const shown = o.shown || (() => st.tab === o.tab);
  const table = () => (o.table ? o.table(t) : t.data?.table);
  const part = (k, f) => (f ? `<div id="${id}-${k}">${f(t)}</div>` : "");
  const open = () => o.open && o.open();
  const around = () => { if (o.head) paint($(id + "-head"), o.head(t), open()); if (o.tail) paint($(id + "-tail"), o.tail(t), open()); };
  t.refresh = o.refresh || coalesce(async () => {
    const p = tblParams(st.views[o.tab], pre);
    if (o.params) o.params(p, t);
    const q = p.toString();
    try { t.data = await api(o.api + (q ? "?" + q : "")); t.err = null; if (o.got) o.got(t); } catch (e) { t.err = e.message; }
    t.render();
    if (o.after) o.after(t);
  });
  // A refresh must not take the search box or an open dropdown from under the human: with focus
  // in the bar only what is around the control repaints. False when focus is elsewhere.
  t.repaint = () => {
    const v = table(), f = document.activeElement;
    if (!v || !$(id + "-body")) return false;
    if (f?.id !== id + "-q" && (f?.dataset?.tq === undefined || !f.closest?.(`#${id}-facets`))) return false;
    if (f.id === id + "-q") paint($(id + "-facets"), tblFacets(v));
    if ($(id + "-chips")) paint($(id + "-chips"), tblChips(v));
    paint($(id + "-body"), o.body(t));
    around();
    return true;
  };
  // The same parts repainted with focus elsewhere: the dropdowns too, with their new counts.
  t.redraw = () => {
    const v = table();
    if ($(id + "-facets")) paint($(id + "-facets"), tblFacets(v));
    if ($(id + "-chips")) paint($(id + "-chips"), tblChips(v));
    paint($(id + "-body"), o.body(t));
    around();
  };
  t.html = () => part("head", o.head) + tblBar(id, table(), o.hint, o.chips !== false) + part("body", o.body) + part("tail", o.tail);
  t.render = o.render || (() => {
    const el = $(elId), m = open();
    if (!el || !shown()) return;
    // A fold just opened is in the page and not yet in the map the html is built from: record it first.
    if (m) el.querySelectorAll("details[data-k]").forEach((d) => { m[d.dataset.k] = d.open; });
    if (!table()) {
      const why = t.err || (t.data?.errors || [])[0];
      // A failed read looks like one, never like an empty table.
      paint(el, why ? `<div class="card err">${esc(why)}</div>` : `<div class="empty">${o.wait || "Loading..."}</div>`);
      return;
    }
    if (t.repaint()) return;
    const box = o.scroller && $(o.scroller), y = box && box.scrollTop;
    if (o.draw) o.draw(t.html()); else paint(el, t.html(), open());
    if (box) box.scrollTop = y;
    seekSection();
  });
  // The view changed: the URL follows it and the server applies it.
  t.view = (patch) => {
    setQuery(tblSet(st.views[o.tab], patch, pre));
    t.all = false;
    if (o.reset) o.reset(t);
    t.refresh();
  };
  // The bar's, the headers' and the more button's events from this table's own block. A picked
  // dropdown lets go of focus, so the answer redraws it with the new counts.
  for (const ev of ["input", "change", "click"]) $(o.on || elId).addEventListener(ev, (e) => {
    if (tblOf(e) !== pre || !shown()) return;
    if (e.type === "click" && e.target.dataset?.all) { t.all = true; t.render(); return; }
    const v = tblPatch(e);
    if (!v) return;
    if (e.type === "change" && e.target.dataset.tq !== undefined) e.target.blur?.();
    t.view(v);
  });
  return t;
}
