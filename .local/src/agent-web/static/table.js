"use strict";
// The shared data table (docs/dashboards.md rule 7). The server applies hub_core::table and
// sends its summary beside the rows (`table`: the query, each state chip's count, each
// header's sort and the sort a click on it gives, each facet's values with their counts and
// the query a tick on each gives). This file only draws that and turns a click or a keystroke into the view keys
// the server reads; what a query means is decided in hub-core alone.

// The view keys, in the tab's URL query (`#infra?q=source:unity&s=failed&sort=started&dir=asc`)
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

// The headers are hidden on a phone, so this dropdown sorts there instead (app.css shows it only
// at phone width). Each option is `key|dir`; the sorted column also offers its opposite.
function tblSort(t) {
  if (!t.columns?.length) return "";
  const opt = (v, label, on) => `<option value="${esc(v)}"${on ? " selected" : ""}>${esc(label)}</option>`;
  const flip = (d) => (d === "asc" ? "desc" : "asc");
  return `<select class="tsort" data-tsv title="sort">${opt("|", "default sort", !t.sort)}` + t.columns.map((c) =>
    opt(`${c.key}|${c.sort || c.next_dir}`, `sort: ${c.key}`, !!c.sort) + (c.sort ? opt(`${c.key}|${flip(c.sort)}`, `sort: ${c.key} reversed`, false) : "")).join("") + `</select>`;
}

// One facet's dropdown: a pill naming the column and what is ticked, opening a checklist of its
// values with their counts. Each box's value is the whole query a tick gives (hub-core decides it:
// ticks on one column OR, columns AND), so a tick is a plain change on [data-tq]. data-fq is the
// view `q` the boxes were built on (tblMenuKeep).
function tblFacet(f, q) {
  const on = f.on || [];
  const label = on.length ? `${f.key}: ${on[0]}${on.length > 1 ? ` +${on.length - 1}` : ""}` : f.key;
  const clear = on.length ? `<button type="button" class="tfclear" data-tqc="${esc(f.clear)}">clear ${esc(f.key)}</button>` : "";
  return `<details class="tfacet${on.length ? " on" : ""}" data-fkey="${esc(f.key)}" data-fq="${esc(q || "")}"><summary title="filter ${esc(f.key)}: tick one or more">${esc(label)}</summary><div class="tfmenu">${clear}` +
    f.values.map((v) => `<label><input type="checkbox" data-tq data-fv="${esc(v.value)}" value="${esc(v.q)}"${v.on ? " checked" : ""}> <span>${esc(v.value)}</span> <span class="n">${v.n}</span></label>`).join("") +
    `</div></details>`;
}

// The facets each table's header drew under its columns, keyed by the summary's facets array (a
// tab that redraws its header from a copy of the summary still shares that array). The bar draws
// the rest: a column the tab does not show, or every facet when no header was drawn (no rows), so
// a filter that empties the table can still be taken off. A caller draws the body before the bar.
const tblDrawn = new WeakMap();
// Draw a table's body before its bar, forgetting what an earlier draw put in the header, so a body
// that now draws no header (no rows) leaves every facet to the bar.
const tblBodyFirst = (t, draw) => { if (t?.facets) tblDrawn.delete(t.facets); return draw(); };
const tblFacets = (t) => { const d = tblDrawn.get(t.facets); return tblSort(t) + t.facets.filter((f) => !d?.has(f.key)).map((f) => tblFacet(f, t.q)).join(""); };
// One count chip, here and on the tabs that still filter their own lists.
const chipBtn = (on, attr, val, label, n) =>
  `<button class="${on ? "on" : ""}" ${attr}="${esc(val)}">${esc(label)} <span class="n">${n}</span></button>`;
// The state chips with their counts; the first keeps every row.
const tblChips = (t) => t.states.map((c, i) => chipBtn(i ? c.name === t.state : !t.state, "data-ts", i ? c.name : "", c.name, c.n)).join("");

// The window buttons a table can carry beside its dropdowns: each writes one URL key (`key`), a blank
// value being the plain view, and `date` adds a day picker on the same key.
function tblDays({ key, on, windows, date }) {
  const b = windows.map(([v, l]) => `<button class="${on === v ? "on" : ""}" data-twin="${esc(key)}" data-tval="${esc(v)}">${esc(l)}</button>`).join("");
  const pick = date ? `<input type="date" class="tdate" data-twin="${esc(key)}" value="${/^\d{4}-\d{2}-\d{2}$/.test(on) ? esc(on) : ""}" title="one day">` : "";
  return `<span class="seg tdays">${b}${pick}</span>`;
}

// The search box, the dropdowns and the chips. `id` names the parts a repaint while the search
// box has focus replaces around it: `<id>-facets` and `<id>-chips`. A tab whose overview tiles are
// its chips (Sessions) passes `chips` false.
function tblBar(id, t, hint, chips = true, days = "") {
  return `<div class="card bfilter qcfilter"><div class="opts"><input id="${id}-q" data-tsearch placeholder="${esc(hint)}" value="${esc(t.q)}" title="key:value matches a column, a repeated key is any of them, -key:value excludes, a word searches the text">` +
    `<span id="${id}-facets">${tblFacets(t)}${days}</span></div></div>` + (chips ? `<div class="seg fseg" id="${id}-chips">${tblChips(t)}</div>` : "");
}

// The header row. `labels` maps a column key to [text, class]; a column it leaves out is not drawn.
// `pre` names the data attributes a click reads (`data-<pre>sort`, `data-<pre>dir`): a second table
// on a tab sorts apart from the first by naming its own.
function tblHead(t, labels, pre = "t") {
  const cols = t.columns.filter((c) => labels[c.key]);
  const facet = new Map((t.facets || []).map((f) => [f.key, f]));
  const mine = cols.filter((c) => facet.has(c.key));
  if (t.facets) tblDrawn.set(t.facets, new Set(mine.map((c) => c.key)));
  // The filter row under the headers: a column with a facet carries its dropdown (fleet-platform's
  // filter row, multi-pick here). tblStamp skips it; a phone shows it as a strip of pills.
  const filters = mine.length ? `<tr class="tfilters" data-phone="filters">` +
    cols.map((c) => (facet.has(c.key) ? `<th>${tblFacet(facet.get(c.key), t.q)}</th>` : `<td></td>`)).join("") + "</tr>" : "";
  return "<tr>" + cols.map((c) => {
    const [label, cls] = labels[c.key];
    const aria = c.sort ? ` aria-sort="${c.sort === "asc" ? "ascending" : "descending"}"` : "";
    const mark = c.sort ? (c.sort === "asc" ? " ^" : " v") : "";
    return `<th${cls ? ` class="${cls}"` : ""}${aria} data-role="${c.role || ""}" data-label="${esc(label)}"><button class="thsort" data-${pre}sort="${esc(c.next_sort)}" data-${pre}dir="${c.next_dir}" title="sort by ${esc(label)}">${esc(label)}${mark}</button></th>`;
  }).join("") + "</tr>" + filters;
}

// The button a capped body ends in; tblTab's listener answers `data-all` (t.all, reset by a view change).
const tblMore = (n, word = "older") => (n > 0 ? `<button class="btn sm" data-all="1">+${n} ${word}</button>` : "");
// The record each cell names (hub_core::links, `Row::link`): the summary sends `links`, one
// column -> href map per row it sent, in the same order, so the page builds no `#...` itself.
const tblLinks = (t, i) => t?.links?.[i] || {};
// A linked cell: an anchor to its page, a URL outside the hub in a new tab; no href, its text.
const tblLink = (href, text, cls = "") => href ? `<a${cls ? ` class="${cls}"` : ""} href="${esc(href)}"${/^https?:/.test(href) ? ' target="_blank" rel="noopener"' : ""}>${esc(text)}</a>` : text ? (cls ? `<span class="${cls}">${esc(text)}</span>` : esc(text)) : "-";

// The view patch an event on the bar or a header asks for, or null when it is not one of theirs.
function tblPatch(e) {
  const t = e.target;
  if (!t || !t.dataset) return null;
  if (e.type === "input" && t.dataset.tsearch != null) return { q: t.value };
  if (e.type === "change" && t.dataset.tsv != null) {
    const [sort, dir] = t.value.split("|");
    return { sort, dir: dir === "asc" ? "asc" : "" };
  }
  if (e.type === "change" && t.dataset.tq != null) return { q: t.value };
  if (e.type === "change" && t.dataset.twin != null) return { [t.dataset.twin]: t.value };
  if (e.type !== "click" || !t.closest) return null;
  const clear = t.closest("[data-tqc]");
  if (clear) return { q: clear.dataset.tqc };
  const sort = t.closest("[data-tsort]");
  if (sort) return { sort: sort.dataset.tsort, dir: sort.dataset.tsort && sort.dataset.tdir === "asc" ? "asc" : "" };
  const chip = t.closest("[data-ts]");
  if (chip) return { s: chip.dataset.ts };
  const win = t.closest("[data-tval]");
  if (win) return { [win.dataset.twin]: win.dataset.tval };
  return null;
}

// A native control whose pick is done: it lets go of focus so the redraw can replace it. A facet's
// checkbox is not one; its menu stays open for the next tick (tblMenuKeep).
const tblDropdown = (el) => el?.dataset?.tsv !== undefined || (el?.dataset?.twin !== undefined && el.dataset.tval === undefined);

// One table of a tab on the shared table, the skeleton every such tab draws with. `o` names:
//   tab    the tab whose URL query (st.views[tab]) holds the view; it is drawn only while open
//   id     the parts' prefix: `<id>-head`, the bar's `<id>-q`, `-facets` and `-chips`, `<id>-body`, `<id>-tail`
//   el     the id of the element it draws into (id), and `on` the one its listener sits on (el);
//          scroller: the scrolling parent whose scrollTop a whole draw keeps
//   pre    the view keys' prefix (tblParams), for a tab's second table; its block carries data-tbl
//   api    the path read with the view keys, plus what params(p, t) adds; with no api the tab reads
//          itself and `refresh` is that read
//   hint   the search box's placeholder; wait: what shows before the first read, under lead(), the
//          html that leads the tab on that path too (an inner strip); chips: false
//          for a tab whose overview tiles are its chips; days(t): what tblDays draws in the bar
//   pages  the server caps the rows, so "+N more" reads them again with params asking for all
//   head, body, tail (t)  the html above the bar, the rows and below them; wrap(html): around the bar and rows (Costs' inner tab); table(t): the summary
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
  const days = () => (o.days ? tblDays(o.days(t)) : "");
  const facets = (v) => tblFacets(v) + days();
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
    if (f?.id !== id + "-q" && (!tblDropdown(f) || !f.closest?.(`#${id}-facets`))) return false;
    paint($(id + "-body"), tblBodyFirst(v, () => o.body(t)));
    if (f.id === id + "-q") paint($(id + "-facets"), facets(v));
    if ($(id + "-chips")) paint($(id + "-chips"), tblChips(v));
    around();
    return true;
  };
  // The same parts repainted with focus elsewhere: the dropdowns too, with their new counts.
  t.redraw = () => {
    const v = table();
    paint($(id + "-body"), tblBodyFirst(v, () => o.body(t)));
    if ($(id + "-facets")) paint($(id + "-facets"), facets(v));
    if ($(id + "-chips")) paint($(id + "-chips"), tblChips(v));
    around();
  };
  const wrap = o.wrap || ((html) => html);
  t.html = () => { const body = tblBodyFirst(table(), () => part("body", o.body)); return part("head", o.head) + wrap(tblBar(id, table(), o.hint, o.chips !== false, days()) + body) + part("tail", o.tail); };
  t.render = o.render || (() => {
    const el = $(elId), m = open();
    if (!el || !shown()) return;
    // A fold just opened is in the page and not yet in the map the html is built from: record it first.
    if (m) el.querySelectorAll("details[data-k]").forEach((d) => { m[d.dataset.k] = d.open; });
    if (!table()) {
      const why = t.err || (t.data?.errors || [])[0];
      // A failed read looks like one, never like an empty table.
      paint(el, (o.lead ? o.lead() : "") + (why ? `<div class="card err">${esc(why)}</div>` : `<div class="empty">${o.wait || "Loading..."}</div>`));
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
  // sort or day dropdown lets go of focus, so the answer redraws it; a facet's menu is reopened.
  for (const ev of ["input", "change", "click"]) $(o.on || elId).addEventListener(ev, (e) => {
    if (tblOf(e) !== pre || !shown()) return;
    if (e.type === "click" && e.target.dataset?.all) { t.all = true; if (o.pages) t.refresh(); else t.render(); return; }
    const v = tblPatch(e);
    if (!v) return;
    if (e.type === "change" && tblDropdown(e.target)) e.target.blur?.();
    t.view(v);
  });
  return t;
}

// A phone row: lead, glance, the rest on a tap. tblHead wrote each column's role on its header; each
// draw is plain innerHTML, so every table the page gains is stamped from its own headers. A row with
// another cell count (a detail, a colspan) is left as it is, and a table with no lead keeps its columns.
const TBL_OPENS = "tr.jr, tr.wr, tr.qr, tr.prop, tr.click, tr[data-open], tr[data-row]";
const tblExpanded = new Set();

function tblStamp(table) {
  const [head, ...rows] = table.rows, heads = [...(head?.cells || [])];
  if (!heads.some((h) => h.dataset.role === "lead")) return;
  table.classList.add("tphone");
  head.dataset.phone = "head";
  for (const tr of rows) {
    if (tr.cells.length !== heads.length || tr.dataset.phone === "filters") continue;
    tr.dataset.phone = "row";
    [...tr.cells].forEach((td, i) => {
      // A control is never hidden: a row's detail need not repeat its buttons.
      td.dataset.role = heads[i].dataset.role || (td.querySelector("button, select, input") ? "glance" : "rest");
      td.dataset.label = heads[i].dataset.label ?? heads[i].textContent.trim();
      if ("named" in heads[i].dataset) td.dataset.named = "";
    });
    if (tblExpanded.has(tr.textContent)) tr.classList.add("tx");
  }
}

// The facet menu open, by its tab, table block (data-tbl), part and column, with the value last
// ticked, how far it is scrolled, and the query a tick or clear asked for (want): a tick or a push
// re-reads the table and the redraw replaces the menu, so each new draw opens it again where it was.
// One menu is open at a time.
let tblMenu = null;
const tblWhere = (d) => `${typeof st === "undefined" ? "" : st.tab}|${d.closest("[data-tbl]")?.dataset.tbl || ""}|${d.closest("[id]")?.id || ""}`;

// A menu sits in a scrolling panel, so it is fixed to the page by its pill rather than clipped:
// under it, or over it when the window has more room there, and never taller than that room.
const TBL_MENU_MAX = 360;
function tblPlace(d) {
  const m = d.querySelector(".tfmenu"), r = d.querySelector("summary")?.getBoundingClientRect?.();
  if (!m || !r) return;
  const below = innerHeight - r.bottom - 6, above = r.top - 6;
  const up = below < Math.min(m.scrollHeight, TBL_MENU_MAX) && above > below;
  m.style.maxHeight = `${Math.round(Math.max(80, Math.min(TBL_MENU_MAX, up ? above : below)))}px`;
  m.style.top = `${Math.round(Math.max(4, up ? r.top - 2 - m.offsetHeight : r.bottom + 2))}px`;
  m.style.left = `${Math.round(Math.max(4, Math.min(r.left, innerWidth - m.offsetWidth - 4)))}px`;
}

// Every box's query is built on the view its menu was drawn from, so until the answer to a tick is
// drawn a second tick would drop the first: a menu drawn from any other view (a redraw from the hash
// change, a poll or a push before the answer lands) waits, its boxes off and focus on its pill.
const tblSameQ = (a, b) => (a || "").trim().split(/\s+/).join(" ") === (b || "").trim().split(/\s+/).join(" ");
function tblBusy(d, busy) {
  d.classList[busy ? "add" : "remove"]("busy");
  d.querySelectorAll("input[data-fv], button[data-tqc]").forEach((i) => { i.disabled = busy; });
}

function tblMenuKeep(root) {
  if (!tblMenu || !root.querySelectorAll) return;
  const ds = [...(root.matches?.("details.tfacet") ? [root] : []), ...root.querySelectorAll("details.tfacet")];
  const d = ds.find((x) => x.dataset.fkey === tblMenu.key && tblWhere(x) === tblMenu.tbl);
  if (!d) return;
  d.open = true;
  tblPlace(d);
  const m = d.querySelector(".tfmenu");
  if (m && tblMenu.top) m.scrollTop = tblMenu.top;
  if (tblMenu.want != null && tblSameQ(d.dataset.fq, tblMenu.want)) tblMenu.want = null;
  if (tblMenu.want != null) tblBusy(d, true);
  const box = tblMenu.want == null && [...d.querySelectorAll("input[data-fv]")].find((i) => i.dataset.fv === tblMenu.fv);
  (box || d.querySelector("summary"))?.focus({ preventScroll: true });
}

function tblMenuShut(except) {
  document.querySelectorAll("details.tfacet[open]").forEach((d) => { if (d !== except) d.open = false; });
}

if (typeof document !== "undefined" && document.addEventListener) {
  // toggle does not bubble; a capture listener sees every menu open and close.
  document.addEventListener("toggle", (e) => {
    const d = e.target;
    if (!d.matches?.("details.tfacet")) return;
    if (d.open) {
      tblMenuShut(d);
      if (tblMenu?.key !== d.dataset.fkey || tblMenu?.tbl !== tblWhere(d)) { tblMenu = { tbl: tblWhere(d), key: d.dataset.fkey, fv: null }; tblBusy(d, false); }
      tblPlace(d);
    } else if (d.isConnected && tblMenu?.key === d.dataset.fkey && tblMenu?.tbl === tblWhere(d)) tblMenu = null;
  }, true);
  document.addEventListener("change", (e) => {
    const d = e.target.closest?.("details.tfacet");
    if (!d || e.target.dataset.fv == null) return;
    tblMenu = { ...tblMenu, tbl: tblWhere(d), key: d.dataset.fkey, fv: e.target.dataset.fv, want: e.target.value };
    tblBusy(d, true);
    d.querySelector("summary")?.focus({ preventScroll: true });
  }, true);
  document.addEventListener("click", (e) => {
    const d = e.target.closest?.("details.tfacet"), clear = d && e.target.closest("[data-tqc]");
    if (!d) { tblMenu = null; tblMenuShut(); } else if (clear) { tblMenu = { ...tblMenu, tbl: tblWhere(d), key: d.dataset.fkey, want: clear.dataset.tqc }; tblBusy(d, true); }
  });
  document.addEventListener("keydown", (e) => {
    const d = e.key === "Escape" && e.target.closest?.("details.tfacet[open]");
    if (!d) return;
    tblMenu = null;
    d.open = false;
    d.querySelector("summary")?.focus();
  });
  // Only while a menu is open: the menu's own scroll is remembered, any other moves it with its pill.
  const follow = () => { if (tblMenu) document.querySelectorAll("details.tfacet[open]").forEach(tblPlace); };
  document.addEventListener("scroll", (e) => {
    if (tblMenu && e.target.classList?.contains("tfmenu")) tblMenu.top = e.target.scrollTop; else follow();
  }, true);
  if (typeof window !== "undefined" && window.addEventListener) window.addEventListener("resize", follow);
}

function tblStampAdded(records) {
  const tables = new Set();
  for (const r of records) for (const n of r.addedNodes) {
    if (n.nodeType !== 1) continue;
    tblMenuKeep(n);
    const own = n.closest("table.tbl");
    if (own) tables.add(own);
    n.querySelectorAll("table.tbl").forEach((t) => tables.add(t));
  }
  tables.forEach(tblStamp);
}

// A row with nothing to open shows its hidden cells in place, and stays open across a redraw.
function tblTap(e) {
  const tr = e.target.closest?.("tr[data-phone=row]");
  if (!tr || tr.matches(TBL_OPENS) || e.target.closest("a, button, select, input, summary")) return;
  if (tr.classList.toggle("tx")) tblExpanded.add(tr.textContent); else tblExpanded.delete(tr.textContent);
}

if (typeof MutationObserver !== "undefined") {
  const main = $("main");
  new MutationObserver(tblStampAdded).observe(main, { childList: true, subtree: true });
  main.addEventListener("click", tblTap);
}
