// Unit tests for the conversation renderer (.local/src/agent-web/static/convo.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The real ui.js, md.js and convo.js load
// into one vm context; convoHtml is a string builder, so no DOM is needed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);
const el = () => new Proxy({}, { get: (t, k) => (k in t ? t[k] : () => el()) });
const ctx = vm.createContext({ console, document: { getElementById: el, addEventListener() {}, createElement: el }, window: { addEventListener() {} }, location: { hash: "" } });
for (const f of ["ui.js", "md.js", "convo.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const html = (evs) => { vm.runInContext("convoReset()", ctx); ctx.__e = evs; return vm.runInContext("convoHtml(__e)", ctx); };

const said = (role, text) => ({ ts: "2026-11-07T10:00:00Z", role, kind: "text", text });
const call = (id, name, text) => ({ ts: "", role: "assistant", kind: "tool_use", id, name, text });
const done = (id, text, error) => ({ ts: "", role: "user", kind: "tool_result", id, text, ...(error ? { error: true } : {}) });

test("a run of calls between two turns is one step group, counted by tool", () => {
  const h = html([said("user", "fix it"), call("a", "Read", "/x"), done("a", "1"), call("b", "Read", "/y"), done("b", "2"), call("c", "Bash", "ls"), done("c", "ok"), said("assistant", "**Done.**")]);
  assert.equal((h.match(/<details class="steps"/g) || []).length, 1);
  assert.match(h, /<summary>3 steps: Read x2, Bash<\/summary>/);
  assert.ok(h.indexOf("fix it") < h.indexOf("steps") && h.indexOf("steps") < h.indexOf("<strong>Done.</strong>"), "turns keep their order");
  assert.match(h, /class="ev user"><div class="ts">2026-11-07 10:00:00<\/div>fix it/);
});

test("a call shows one line and its mark; its result stays out of the DOM until opened", () => {
  const h = html([call("a", "Bash", "make test\nsecond line"), done("a", "SECRET OUTPUT")]);
  assert.match(h, /data-sid="a" data-n="Bash"><button class="stl" data-step><span class="stx ok"[^>]*>ok<\/span><b>Bash<\/b> <span class="sta">make test<\/span>/);
  assert.doesNotMatch(h, /SECRET OUTPUT|second line/);
  assert.equal(vm.runInContext(`cv.results.get("a").text`, ctx), "SECRET OUTPUT");
});

test("a failed call is marked and its group starts open (exceptions first)", () => {
  const h = html([call("a", "Edit", "/f"), done("a", "no match", true), said("assistant", "retrying")]);
  assert.match(h, /<details class="steps" open>/);
  assert.match(h, /class="st err"/);
  assert.match(h, /stx bad/);
  assert.doesNotMatch(html([call("a", "Edit", "/f"), done("a", "ok")]), /steps" open/, "a green group starts folded");
});

test("a result whose call is on an older page pairs when that page is read", () => {
  vm.runInContext("convoReset()", ctx);
  ctx.__e = [done("z", "late result"), said("assistant", "next")];
  const newest = vm.runInContext("convoHtml(__e)", ctx);
  assert.doesNotMatch(newest, /late result|data-n="result"/, "no orphan row for a call not read yet");
  ctx.__e = [call("z", "Grep", "pattern")];
  assert.match(vm.runInContext("convoHtml(__e)", ctx), /data-sid="z"[^]*stx ok/, "the older call draws with its result's mark");
});

test("a result with no id, from a transcript older than ids, is a step of its own", () => {
  const h = html([{ ts: "", role: "user", kind: "tool_result", text: "plain old result" }]);
  assert.match(h, /<summary>1 step: result<\/summary>/);
  assert.match(h, /<b>result<\/b> <span class="sta">plain old result/);
});

test("text is escaped: a user turn as typed, an agent turn through md", () => {
  const h = html([said("user", "<b>hi</b>"), call("a", "Bash", "echo <x>")]);
  assert.match(h, /&lt;b&gt;hi&lt;\/b&gt;/);
  assert.match(h, /echo &lt;x&gt;/);
  assert.equal(html([said("assistant", "   ")]), "", "an empty turn draws nothing");
});
