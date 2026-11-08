// Tab Keeper decisions: which tab a new tab lands in, and what a tick discards, saves or closes.
import test from "node:test";
import assert from "node:assert/strict";
import "../../.config/firefox/tab-keeper/rules.js";

const { withDefaults, configErrors, dedupeAction, planTick } = globalThis.TabKeeperRules;

const HOUR = 3600e3;
const DAY = 24 * HOUR;
const NOW = 1000 * DAY;
let nextId = 1;
const tab = (url, extra = {}) => ({
  id: nextId++, url, title: "t", hidden: false, active: false, pinned: false, audible: false,
  discarded: false, cookieStoreId: "c1", lastAccessed: NOW, ...extra,
});
const config = (extra = {}) => withDefaults({ singleTabHosts: ["*.lab.test"], ...extra });

test("a second tab on a single-tab site lands in the open one", () => {
  const open = tab("https://agents.lab.test/?session=1");
  const action = dedupeAction(tab("https://agents.lab.test/"), [open], null, config());
  assert.equal(action.keeper, open);
  assert.equal(action.navigate, false);
});

test("a deep link navigates the open tab", () => {
  const open = tab("https://agents.lab.test/");
  const action = dedupeAction(tab("https://agents.lab.test/queue"), [open], null, config());
  assert.equal(action.navigate, true);
});

test("a single-tab site matches across containers and picks the most recent", () => {
  const old = tab("https://agents.lab.test/", { cookieStoreId: "c2", lastAccessed: NOW - DAY });
  const recent = tab("https://agents.lab.test/", { cookieStoreId: "c3" });
  assert.equal(dedupeAction(tab("https://agents.lab.test/"), [old, recent], null, config()).keeper, recent);
});

test("elsewhere only the exact url in the same container is a duplicate", () => {
  const open = tab("https://example.test/a");
  assert.equal(dedupeAction(tab("https://example.test/a"), [open], null, config()).keeper, open);
  assert.equal(dedupeAction(tab("https://example.test/b"), [open], null, config()), null);
  assert.equal(dedupeAction(tab("https://example.test/a", { cookieStoreId: "c2" }), [open], null, config()), null);
});

test("a tab opened from its own site stays", () => {
  const open = tab("https://example.test/a");
  assert.equal(dedupeAction(tab("https://example.test/a"), [open], open, config()), null);
});

test("hidden tabs are neither landed in nor removed", () => {
  const hidden = tab("https://agents.lab.test/", { hidden: true });
  assert.equal(dedupeAction(tab("https://agents.lab.test/"), [hidden], null, config()), null);
  const open = tab("https://agents.lab.test/");
  assert.equal(dedupeAction(tab("https://agents.lab.test/", { hidden: true }), [open], null, config()), null);
});

test("a tab never matches itself and non-web pages are left alone", () => {
  const self = tab("https://agents.lab.test/");
  assert.equal(dedupeAction(self, [self], null, config()), null);
  assert.equal(dedupeAction(tab("file:///tmp/x"), [tab("file:///tmp/x")], null, config()), null);
});

const plan = (tabs, extra) => planTick(tabs, NOW, config(extra), { c1: "Personal", bank: "Banking" });
const ago = (ms, extra = {}) => tab("https://example.test/", { lastAccessed: NOW - ms, ...extra });

test("idle tabs discard, old tabs sweep, recent tabs stay", () => {
  const [recent, idle, old] = [ago(HOUR), ago(3 * HOUR), ago(8 * DAY)];
  const result = plan([recent, idle, old]);
  assert.deepEqual(result.discard, [idle]);
  assert.deepEqual(result.sweep, [old]);
  assert.deepEqual(result.close, []);
});

test("pinned, active, audible and non-web tabs are untouched", () => {
  const result = plan([
    ago(9 * DAY, { pinned: true }),
    ago(9 * DAY, { active: true }),
    ago(9 * DAY, { audible: true }),
    tab("file:///tmp/x", { lastAccessed: NOW - 9 * DAY }),
  ]);
  assert.deepEqual(result, { discard: [], sweep: [], close: [] });
});

test("hidden and never-close container tabs discard but never close", () => {
  const hidden = ago(9 * DAY, { hidden: true });
  const bank = ago(9 * DAY, { cookieStoreId: "bank" });
  const result = plan([hidden, bank], { neverCloseContainers: ["Banking"] });
  assert.deepEqual(result.discard, [hidden, bank]);
  assert.deepEqual(result.sweep, []);
  assert.deepEqual(result.close, []);
});

test("closeWithoutSaving hosts close and are not saved", () => {
  const mail = tab("https://mail.test/", { lastAccessed: NOW - 8 * DAY });
  const result = plan([mail], { closeWithoutSaving: ["mail.test"] });
  assert.deepEqual(result.close, [mail]);
  assert.deepEqual(result.sweep, []);
});

test("neverDiscardHosts keep running, and a discarded tab is not discarded again", () => {
  const chat = tab("https://chat.test/", { lastAccessed: NOW - 3 * HOUR });
  assert.deepEqual(plan([chat], { neverDiscardHosts: ["chat.test"] }).discard, []);
  assert.deepEqual(plan([ago(3 * HOUR, { discarded: true })]).discard, []);
});

test("closing is capped per tick, oldest first", () => {
  const [older, oldest] = [ago(8 * DAY), ago(30 * DAY)];
  assert.deepEqual(plan([older, oldest], { maxSweepPerTick: 1 }).sweep, [oldest]);
});

test("dry run is the default and config mistakes are reported", () => {
  assert.equal(withDefaults({}).dryRun, true);
  assert.deepEqual(configErrors({ dryrun: false }), ["unknown setting: dryrun"]);
  assert.deepEqual(configErrors({ sweepDays: "7" }), ["wrong type: sweepDays"]);
  assert.deepEqual(configErrors({ singleTabHosts: "x" }), ["wrong type: singleTabHosts"]);
  assert.deepEqual(configErrors({ dryRun: false, sweepDays: 3 }), []);
});
