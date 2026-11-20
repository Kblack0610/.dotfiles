"use strict";
// The home-screen widget (/widget): the cards the server put in the page, drawn by the same
// cardHtml as Home's grid, and the time they were read. A web-widget app re-loads the page on its
// own timer or on a tap, so the page reads nothing itself.
function drawWidget() {
  const d = JSON.parse($("widget-data").textContent);
  const at = new Date(d.at * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  // The cards link the app's tabs by hash (#home), which from here would stay on this page; the
  // CSP's base-uri 'none' rules out <base>, so each link is made the app's own.
  const app = (l) => (typeof l === "string" && l.startsWith("#") ? "/" + l : l);
  const mine = (x) => ({ ...x, link: app(x.link) });
  const own = (c) => ({ ...mine(c), parts: c.parts.map(mine), first: c.first.map(mine) });
  const cards = d.cards.length ? d.cards.map((c) => cardHtml(own(c))).join("") : `<div class="empty">No card matches the widget's cards= list.</div>`;
  const missing = (d.missing || []).length ? `<span class="warn">no card named ${esc(d.missing.join(", "))}</span> ` : "";
  $("widget").innerHTML = `<div class="wgrid">${cards}</div><div class="wat muted">${missing}as of ${esc(at)}</div>`;
}
drawWidget();
