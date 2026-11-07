"use strict";
// The flow strip, drawn once for Home and the Queue tab: hub-core's `flow::Strip`
// (inbox | board | queued | running | needs you | done 24h | drain), which both pages receive
// ready-made (`flow` in /api/home and /api/flow). A chip opens the Queue on its filter, the board
// chip opens Projects; a step past its age bound is amber, the only colour. A count the reader
// did not return is `-`, never 0 (the strip words it so).

function flowHref(to) {
  if (to.tab === "projects") return "#projects";
  return "#" + to.tab + (to.state ? "?s=" + encodeURIComponent(to.state) : "");
}

function flowChip(c) {
  const text = esc(`${c.label} ${c.value ?? "-"}`);
  const cls = "cchip fchip" + (c.hot ? " warn" : "");
  return c.to ? `<a class="${cls}" href="${esc(flowHref(c.to))}" data-flow="${esc(c.key)}">${text}</a>` : `<span class="${cls}" data-flow="${esc(c.key)}">${text}</span>`;
}

function flowHtml(strip, grafana) {
  if (!strip) return '<div class="flow muted">reading</div>';
  const note = strip.error ? `<span class="warn">inbox, board: ${esc(strip.error)}</span>`
    : strip.as_of ? `inbox, board as of ${esc(strip.as_of)}`
    : strip.absent ? "inbox, board: no gauges" : "";
  const graph = grafana ? ` <a class="glink" href="${esc(grafana)}/d/kb-agents-overview" target="_blank" rel="noopener">graph</a>` : "";
  return `<div class="flow">${strip.chips.map(flowChip).join(" ")}` +
    (strip.bottleneck ? `<div class="qwarn">! ${esc(strip.bottleneck)}</div>` : "") +
    (note || graph ? `<div class="muted fnote">${note}${graph}</div>` : "") + `</div>`;
}
