// The open tab's sections, listed under its button in the sidebar (docs/dashboards.md, Sidebar).
// They are read off the page, each `sec-` anchor and its heading, so the list is what the board
// drew. Daily and an open session have their own nav and no anchors, so they list nothing.
const outline = document.createElement("div");
outline.className = "outl";
let outlineKey = null;

function headingOf(e) {
  // A heading's first text is its title; a count or note after it sits in its own span. A
  // wrapper div has no title of its own, and an h2 inside it belongs to something else.
  const h = e.matches("h2") ? e : e.matches("details") ? e.querySelector("h2") || e.querySelector("summary") : null;
  return h && h.firstChild ? h.firstChild.textContent.trim() : "";
}

function drawOutline() {
  const items = tabAnchors().map((e) => [e.id.slice(4), headingOf(e)]).filter((x) => x[1]);
  const shown = items.length >= 2 ? items : [];
  const key = st.tab + JSON.stringify(shown);
  if (key === outlineKey) return; // a live repaint rarely changes the sections
  outlineKey = key;
  outline.innerHTML = shown.map(([id, title]) => `<button data-sec="${esc(id)}">${esc(title)}</button>`).join("");
  $("tab-" + st.tab).after(outline);
}

outline.onclick = (e) => {
  const b = e.target.closest("[data-sec]");
  if (!b) return;
  st.section = b.dataset.sec;
  seekSection();
  st.section = null; // a repaint can have taken the anchor; the next paint must not jump there
  menuOpen(false);
};

// A board repaints its own HTML from many places, and a tab change toggles `hidden`; one
// observer sees both, coalesced so a burst of repaints reads the page once.
let outlinePending = false;
new MutationObserver(() => {
  if (outlinePending) return;
  outlinePending = true;
  requestAnimationFrame(() => { outlinePending = false; drawOutline(); });
}).observe($("main"), { childList: true, subtree: true, attributes: true, attributeFilter: ["hidden"] });
drawOutline();
