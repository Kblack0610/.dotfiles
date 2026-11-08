"use strict";
// The open session's conversation, drawn the way an IDE agent panel draws it: the human's turns
// as bubbles, the agent's text as markdown, and each run of tool calls between them folded into
// one step group ("6 steps: Read x3, Bash x2, Edit"), one line a call. A call's full input and
// its result stay in `cv` until the step is opened, so a long session's DOM holds lines, not
// output. Events come from /api/transcript (transcript.rs), which pairs a call and its result by
// `id`; app.js pages them in, newest first, and appends what arrives.

const cv = { inputs: new Map(), results: new Map() };
// How much of a call's input its one line shows; the rest is in the opened step.
const STEP_LINE = 160;

function convoReset() { cv.inputs.clear(); cv.results.clear(); }

const stepMark = (r) => (!r ? "" : r.error ? '<span class="stx bad" title="failed">x</span>' : '<span class="stx ok" title="done">ok</span>');

function stepRow(e) {
  const id = e.id || "";
  const r = id && cv.results.get(id);
  const line = e.text.split("\n")[0].slice(0, STEP_LINE);
  return `<div class="st${r && r.error ? " err" : ""}" data-sid="${esc(id)}" data-n="${esc(e.name || "tool")}">` +
    `<button class="stl" data-step>${stepMark(r)}<b>${esc(e.name || "tool")}</b> <span class="sta">${esc(line)}</span></button></div>`;
}

// A result with no id (a transcript from before ids) is a step of its own, so nothing is dropped.
function orphanRow(e) {
  const key = "r" + cv.results.size;
  cv.results.set(key, { text: e.text, error: e.error });
  return `<div class="st${e.error ? " err" : ""}" data-sid="${key}" data-n="result"><button class="stl" data-step>${stepMark(e)}<b>result</b> <span class="sta">${esc(e.text.split("\n")[0].slice(0, STEP_LINE))}</span></button></div>`;
}

// "6 steps: Read x3, Bash x2, Edit", counted from the rows the group holds.
function stepsLabel(names) {
  const n = new Map();
  for (const x of names) n.set(x, (n.get(x) || 0) + 1);
  const parts = [...n].map(([k, c]) => (c > 1 ? `${k} x${c}` : k));
  return `${names.length} step${names.length === 1 ? "" : "s"}: ${parts.join(", ")}`;
}

function groupHtml(rows, names, open) {
  return `<details class="steps"${open ? " open" : ""}><summary>${esc(stepsLabel(names))}</summary><div class="stg">${rows.join("")}</div></details>`;
}

function textHtml(e) {
  const ts = e.ts ? esc(e.ts.replace("T", " ").slice(0, 19)) : "";
  // What the human typed is shown as typed; what an agent wrote is markdown.
  return e.role === "user"
    ? `<div class="ev user">${ts ? `<div class="ts">${ts}</div>` : ""}${esc(e.text)}</div>`
    : `<div class="ev md" title="${ts}">${md(e.text)}</div>`;
}

// One page of events as HTML. Results are remembered before any row draws, so a call and its
// result on the same page draw paired. A result whose call is already on screen marks that row.
function convoHtml(events) {
  for (const e of events) {
    if (e.kind === "tool_use" && e.id) cv.inputs.set(e.id, e.text);
    if (e.kind === "tool_result" && e.id) cv.results.set(e.id, { text: e.text, error: !!e.error });
  }
  const out = [];
  let rows = [], names = [], err = false;
  const flush = () => {
    if (rows.length) out.push(groupHtml(rows, names, err));
    rows = []; names = []; err = false;
  };
  for (const e of events) {
    if (e.kind === "tool_use") {
      rows.push(stepRow(e)); names.push(e.name || "tool");
      err ||= !!(e.id && cv.results.get(e.id)?.error);
    } else if (e.kind === "tool_result") {
      // A paired result draws on its call's row, which may be on an older page not read yet.
      if (e.id) continue;
      rows.push(orphanRow(e)); names.push("result"); err ||= !!e.error;
    } else if (e.text.trim()) { flush(); out.push(textHtml(e)); }
  }
  flush();
  return out.join("");
}

// A result that arrived after its call drew: mark the row, and open a failure (rule 4).
function convoMark(root, events) {
  for (const e of events) {
    if (e.kind !== "tool_result" || !e.id) continue;
    const row = root.querySelector(`.st[data-sid="${globalThis.CSS?.escape ? CSS.escape(e.id) : e.id}"]`);
    if (!row) continue;
    row.querySelector(".stx")?.remove();
    row.firstElementChild.insertAdjacentHTML("afterbegin", stepMark(e));
    if (e.error) { row.classList.add("err"); row.closest("details").open = true; }
  }
}

// Append a page under what is drawn. Calls that continue the last step group join it, so a
// live session's run of tools stays one group as it grows.
function convoAppend(root, events) {
  const html = convoHtml(events);
  convoMark(root, events);
  const last = root.lastElementChild;
  const tmp = document.createElement("div");
  tmp.innerHTML = html;
  const first = tmp.firstElementChild;
  if (last && last.matches("details.steps") && first && first.matches("details.steps")) {
    last.querySelector(".stg").append(...first.querySelector(".stg").children);
    const names = [...last.querySelectorAll(".st")].map((r) => r.dataset.n);
    last.querySelector("summary").textContent = stepsLabel(names);
    if (first.open) last.open = true;
    first.remove();
  }
  root.append(...tmp.childNodes);
}

// Open or close one step: its full input and result go into the DOM only while it is open.
function convoStep(btn) {
  const row = btn.closest(".st"), id = row.dataset.sid;
  const shown = row.querySelector(".stb");
  if (shown) { shown.remove(); return; }
  const input = cv.inputs.get(id), r = cv.results.get(id);
  const parts = [];
  if (input && (input.length > STEP_LINE || input.includes("\n"))) parts.push(`<pre class="sti">${esc(input)}</pre>`);
  parts.push(r ? `<pre>${esc(r.text) || '<span class="muted">(no output)</span>'}</pre>` : '<div class="muted">no result yet</div>');
  row.insertAdjacentHTML("beforeend", `<div class="stb">${parts.join("")}</div>`);
}
