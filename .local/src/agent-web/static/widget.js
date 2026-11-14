"use strict";
// The home-screen widget (/widget): the cards the server put in the page, drawn by the same
// cardHtml as Home's grid, and the time they were read. A web-widget app re-loads the page on its
// own timer or on a tap, so the page reads nothing itself.
function drawWidget() {
  const d = JSON.parse($("widget-data").textContent);
  const at = new Date(d.at * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const cards = d.cards.length ? d.cards.map(cardHtml).join("") : `<div class="empty">No card matches the widget's cards= list.</div>`;
  $("widget").innerHTML = `<div class="wgrid">${cards}</div><div class="wat muted">as of ${esc(at)}</div>`;
}
drawWidget();
