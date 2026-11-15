// Section heads (static/ui.js secHead), run from tests/unit/agent_web_queue.bats: a head is its
// title and its count, never a sentence beside it (docs/dashboards.md, Section head). The sweep
// reads every tab's source, so a hand-written head, and the prose it invites, cannot come back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);
const ctx = vm.createContext({});
vm.runInContext(readFileSync(new URL("ui.js", dir), "utf8") + ";this.secHead = secHead;", ctx, { filename: "ui.js" });
const { secHead } = ctx;

test("a head is its title and its count, escaped, with an anchor id", () => {
  assert.equal(secHead("queue", "Queue", 42), `<h2 class="sec" id="sec-queue">Queue <span class="n">42</span></h2>`);
  assert.equal(secHead("", "A & B", "3 of 9"), `<h2 class="sec">A &amp; B <span class="n">3 of 9</span></h2>`);
  assert.equal(secHead(null, "Done today", null, null, "h3"), `<h3 class="sec">Done today</h3>`);
  assert.equal(secHead("x", "Runs", ""), `<h2 class="sec" id="sec-x">Runs</h2>`, "an empty count draws nothing");
});

test("a problem hues the title, and ok or unknown draws plain", () => {
  assert.match(secHead("burn", "Burn", null, "bad"), /^<h2 class="sec bad" id="sec-burn">Burn<\/h2>$/);
  assert.match(secHead("burn", "Burn", null, "warn"), /class="sec warn"/);
  for (const l of ["ok", "nodata", undefined]) assert.match(secHead("burn", "Burn", null, l), /class="sec"/);
});

test("every tab draws its section heads through secHead", () => {
  const bad = [];
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".js") && f !== "ui.js")) {
    readFileSync(new URL(f, dir), "utf8").split("\n").forEach((l, i) => {
      if (/<h[23] class="sec/.test(l)) bad.push(`${f}:${i + 1}`);
    });
  }
  assert.deepEqual(bad, [], "a hand-written section head; use secHead(id, title, count)");
});
