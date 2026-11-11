// Tab Keeper: carries out what rules.js decides. dryRun logs and touches nothing.
const { fromPolicy, karakeepOrigin, hostOf, dedupeAction, planTick } = globalThis.TabKeeperRules;

const TICK = "tick";
const TICK_MINUTES = 60; // no event exists for "this tab has gone idle", so sample hourly
const LOG_LIMIT = 200;
const REQUEST_TIMEOUT_MS = 15000;

// Tabs opened but not yet on a web page. The background page can sleep between a Ctrl+T and the
// typed address, so this lives in session storage rather than in memory alone.
let fresh = new Set();
const ready = browser.storage.session.get("fresh").then((stored) => {
  fresh = new Set(stored.fresh ?? []);
});
const saveFresh = () => browser.storage.session.set({ fresh: [...fresh] });

// storage.managed throws when the policy has no entry for this add-on; fromPolicy names that.
const policy = () => browser.storage.managed.get(["config", "karakeepKey"]).catch(() => null);

async function state() {
  const [stored, managed] = await Promise.all([browser.storage.local.get(["paused", "lastFailure"]), policy()]);
  const { config, key, problem } = fromPolicy(managed);
  const granted = !config.karakeepUrl || (await browser.permissions.contains({ origins: [karakeepOrigin(config.karakeepUrl)] }));
  return {
    ...stored,
    config,
    karakeepKey: key,
    problem: problem ?? (granted ? null : "Karakeep access not granted: open Tab Keeper options and click Grant"),
  };
}

async function log(entry) {
  const { log: entries = [] } = await browser.storage.local.get("log");
  entries.push({ at: new Date().toISOString(), ...entry });
  await browser.storage.local.set({ log: entries.slice(-LOG_LIMIT) });
}

async function showBadge() {
  const { config, paused, lastFailure, problem } = await state();
  const text = paused ? "off" : problem || lastFailure ? "!" : config.dryRun ? "dry" : "";
  await browser.action.setBadgeText({ text });
  const title = problem ? `Tab Keeper: ${problem}` : lastFailure ? `Tab Keeper: last save failed: ${lastFailure}` : "Tab Keeper: click to pause or resume dedupe";
  await browser.action.setTitle({ title });
}

async function togglePaused() {
  const { paused } = await state();
  await browser.storage.local.set({ paused: !paused });
  await showBadge();
}

async function onCreated(tab) {
  await ready;
  if (tab.discarded) return; // a restored session, not a tab the user just opened
  fresh.add(tab.id);
  await saveFresh();
}

async function onRemoved(tabId) {
  await ready;
  if (fresh.delete(tabId)) await saveFresh();
}

async function onUpdated(tabId, change, tab) {
  if (!change.url) return;
  await ready;
  if (!fresh.has(tabId) || !hostOf(change.url)) return;
  fresh.delete(tabId);
  await saveFresh();

  const { config, paused } = await state();
  if (paused) return;

  const tabs = await browser.tabs.query({});
  const opener = tabs.find((other) => other.id === tab.openerTabId);
  const action = dedupeAction({ ...tab, url: change.url }, tabs, opener, config);
  if (!action) return;

  const { keeper, navigate } = action;
  if (!config.dryRun) {
    await browser.tabs.update(keeper.id, navigate ? { active: true, url: change.url } : { active: true });
    await browser.windows.update(keeper.windowId, { focused: true });
    await browser.tabs.remove(tabId);
  }
  await log({ kind: "dedupe", dryRun: config.dryRun, url: change.url, navigate });
}

async function saveToKarakeep(tab, config, key) {
  if (!config.karakeepUrl || !key) throw new Error("Karakeep url or key is not set");
  const post = async (path, body) => {
    const response = await fetch(`${config.karakeepUrl}/api/v1${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) throw new Error(`${path} answered ${response.status}`);
    return response.json();
  };
  const bookmark = await post("/bookmarks", {
    type: "link",
    url: tab.url,
    title: tab.title?.slice(0, 1000),
    source: "extension",
  });
  await post(`/bookmarks/${bookmark.id}/tags`, { tags: [{ tagName: config.sweepTag }] });
}

async function tick() {
  const { config, karakeepKey } = await state();
  const [tabs, containers] = await Promise.all([browser.tabs.query({}), browser.contextualIdentities.query({})]);
  const names = Object.fromEntries(containers.map((c) => [c.cookieStoreId, c.name]));
  const plan = planTick(tabs, Date.now(), config, names);
  const counts = { discard: plan.discard.length, sweep: plan.sweep.length, close: plan.close.length };

  if (config.dryRun) {
    const urls = (list) => list.map((tab) => tab.url);
    await log({ kind: "tick", dryRun: true, ...counts, wouldSweep: urls(plan.sweep), wouldClose: urls(plan.close) });
    return;
  }

  if (plan.discard.length) await browser.tabs.discard(plan.discard.map((tab) => tab.id));

  // A tab closes only once Karakeep holds it; a failed save leaves it open for the next tick.
  let failure = null;
  const saved = [];
  for (const tab of plan.sweep) {
    try {
      await saveToKarakeep(tab, config, karakeepKey);
      saved.push(tab);
    } catch (error) {
      failure = error.message;
      await log({ kind: "save-failed", url: tab.url, error: failure });
    }
  }
  const closing = [...saved, ...plan.close];
  if (closing.length) await browser.tabs.remove(closing.map((tab) => tab.id));

  if (failure) await browser.storage.local.set({ lastFailure: failure });
  else await browser.storage.local.remove("lastFailure");
  await log({ kind: "tick", dryRun: false, ...counts, saved: saved.map((tab) => tab.url) });
  await showBadge();
}

browser.tabs.onCreated.addListener(onCreated);
browser.tabs.onRemoved.addListener(onRemoved);
browser.tabs.onUpdated.addListener(onUpdated);
browser.action.onClicked.addListener(togglePaused);
browser.commands.onCommand.addListener((command) => {
  if (command === "toggle-paused") togglePaused();
});
browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === TICK) tick();
});
browser.storage.local.onChanged.addListener(showBadge);
browser.permissions.onAdded.addListener(showBadge);
browser.permissions.onRemoved.addListener(showBadge);
browser.runtime.onMessage.addListener((message) => {
  if (message === "tick") return tick();
  // The options page gets the settings and the problem, never the key.
  if (message === "state") return state().then(({ config, problem }) => ({ config, problem }));
});

// 0.1.x kept pasted settings and the key here; the policy owns both now.
browser.storage.local.remove(["config", "karakeepKey"]);

// create() restarts the period, and this file runs on every wake, so only create it when missing.
browser.alarms.get(TICK).then((alarm) => alarm ?? browser.alarms.create(TICK, { periodInMinutes: TICK_MINUTES }));
showBadge();
