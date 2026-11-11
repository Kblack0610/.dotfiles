"use strict";
// The flow strip on Home: hub-core's `flow::Strip` (inbox | board | queued | running | needs you |
// done 24h | drain), received ready-made (`flow` in /api/home). A chip opens the Queue on its filter, the board
// chip opens the Board; a step past its age bound is amber, the only colour. A count the reader
// did not return is `-`, never 0 (the strip words it so).

function flowHref(to) {
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
    : strip.absent ? "inbox, board: no snapshot" : "";
  const graph = grafana ? ` <a class="glink" href="${esc(grafana)}/d/kb-agents-overview" target="_blank" rel="noopener">graph</a>` : "";
  return `<div class="flow">${strip.chips.map(flowChip).join(" ")}` +
    (strip.bottleneck ? `<div class="qwarn">! ${esc(strip.bottleneck)}</div>` : "") +
    (note || graph ? `<div class="muted fnote">${note}${graph}</div>` : "") + `</div>`;
}

// The pipeline line that leads the Queue tab: hub-core's `flow::Rail` (`line` in /api/flow), one
// point per step on a rail, the open step's detail after it. A click picks a step; the worst
// starts open. Amber is past its age bound, red is nothing can leave, and a problem alone is
// neither. The hub draws the same builder (`flowline.rs`).
function railNode(n, open) {
  const cls = "rnode" + (n.stopped ? " stopped" : n.hot ? " hot" : "") + (open ? " sel" : "");
  const mark = n.stopped || n.hot ? "!" : "";
  return `<button class="${cls}" data-rail="${esc(n.key)}" aria-pressed="${open}"><span class="rdot"></span>` +
    `<span class="rcount">${mark}${esc(n.count ?? "-")}</span><span class="rlabel">${esc(n.label)}</span>` +
    `<span class="rsub">${esc(n.sub)}</span></button>`;
}

function railProblem(t) {
  return t.item ? `<a class="rprob" href="${esc("#queue?q=" + encodeURIComponent(t.item))}">${esc(t.text)}</a>`
    : `<span class="rprob">${esc(t.text)}</span>`;
}

function railDetail(n) {
  const view = n.to ? ` <a class="glink" href="${esc(flowHref(n.to))}">open</a>` : "";
  return `<div class="rdetail">` +
    (n.stop ? `<div class="rstop">Stopped: ${esc(n.stop)}</div>` : "") +
    n.facts.map((f) => `<div>${esc(f)}</div>`).join("") +
    (n.problems_n ? `<div class="rphead">Problems, 24h: ${n.problems_n}${view}</div>${n.problems.map(railProblem).join("")}` : view && `<div>${view}</div>`) +
    (n.elsewhere ? `<div class="muted">${esc(n.elsewhere)}</div>` : "") + `</div>`;
}

function railHtml(r, picked, grafana) {
  const found = r.nodes.findIndex((n) => n.key === picked);
  const at = found < 0 ? r.worst : found;
  const pts = r.nodes.map((n, i) => railNode(n, i === at) + (i === at ? railDetail(n) : "")).join("");
  const age = r.as_of ? `<span class="${r.stale ? "rstop" : ""}">as of ${esc(r.as_of)}${r.stale ? " (stale)" : ""}</span>`
    : r.stale ? `<span class="rstop">age unknown</span>` : r.reading ? "reading" : "";
  const trouble = r.error ? `inbox, board: ${r.error}` : r.absent ? "inbox, board: no snapshot" : "";
  const graph = grafana ? ` <a class="glink" href="${esc(grafana)}/d/kb-agents-overview" target="_blank" rel="noopener">graph</a>` : "";
  return `<div class="flow"><div class="rail">${pts}</div>` +
    (trouble ? `<div class="rstop">${esc(trouble)}</div>` : "") +
    (age || graph ? `<div class="muted fnote">${age}${graph}</div>` : "") + `</div>`;
}
