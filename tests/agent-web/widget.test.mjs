// Unit tests for the home-screen widget (.local/src/agent-web/static/widget.js), run by `node
// --test` from tests/unit/agent_web_queue.bats. widget.html's own scripts load into one vm context
// in its order; only the DOM is a stub. The cards are hub_core::cards, tested in Rust.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);
const page = readFileSync(new URL("../src/widget.html", dir), "utf8");
const scripts = [...page.matchAll(/static\/([a-z]+\.js)/g)].map((m) => m[1]);

function draw(data) {
  const els = { "widget-data": { textContent: JSON.stringify(data) }, widget: { innerHTML: "" } };
  const ctx = vm.createContext({ console, document: { getElementById: (id) => els[id] }, window: {}, location: { hash: "" } });
  for (const f of scripts) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
  return els.widget.innerHTML;
}

const card = (o) => ({ tab: "needs", title: "Needs you", big: "3", unit: "waiting on you", level: "warn", bar: [{ level: "warn", n: 3 }],
  parts: [{ label: "Asks", value: "2", level: "warn" }], first_head: "Oldest", first: [{ text: "old ask", sub: "2h dotfiles", level: "warn", link: null }],
  counted: "", error: null, link: "#home", ...o });

test("the widget page loads cards.js, the card Home draws, before widget.js", () => {
  assert.deepEqual(scripts, ["ui.js", "cards.js", "widget.js"]);
});

test("the widget draws each card it was sent, with its level word, and the time it was read", () => {
  const html = draw({ at: 0, cards: [card(), card({ tab: "red", title: "Main red", big: "0", level: "ok", first: [] })] });
  assert.equal((html.match(/class="kcard"/g) || []).length, 2);
  assert.match(html, /data-card="needs"/);
  assert.match(html, /needs a look/);
  assert.match(html, /as of /);
  assert.doesNotMatch(html, /undefined/);
  // The links open the app, not a hash on the widget page.
  assert.match(html, /href="\/#home"/);
  assert.doesNotMatch(html, /href="#/);
});

test("a card that could not be read says why, and no card matching is said, never an empty widget", () => {
  assert.match(draw({ at: 0, cards: [card({ big: "NO DATA", level: "nodata", error: "fleet-sessions: timed out", first: [] })] }), /fleet-sessions: timed out/);
  assert.match(draw({ at: 0, cards: [] }), /No card matches/);
  assert.match(draw({ at: 0, cards: [card()], no_card: ["redd"] }), /no card named redd/);
});
