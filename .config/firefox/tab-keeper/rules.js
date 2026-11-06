// Tab Keeper decisions, free of browser APIs so tests/tab-keeper can run them in node.
// background.js does what these return. Host names and thresholds are config, never code.
(() => {
  const DEFAULTS = {
    dryRun: true,
    discardHours: 2,
    sweepDays: 7,
    maxSweepPerTick: 20,
    sweepTag: "tab-sweep",
    karakeepUrl: "",
    singleTabHosts: [],
    closeWithoutSaving: [],
    neverDiscardHosts: [],
    neverCloseContainers: [],
  };

  const HOUR = 3600e3;
  const DAY = 24 * HOUR;

  function withDefaults(config) {
    return { ...DEFAULTS, ...config };
  }

  // A typo such as `dryrun: false` must fail loudly, not leave a setting quietly unapplied.
  function configErrors(config) {
    const errors = [];
    if (config === null || typeof config !== "object" || Array.isArray(config)) {
      return ["config must be a JSON object"];
    }
    for (const [key, value] of Object.entries(config)) {
      if (!(key in DEFAULTS)) {
        errors.push(`unknown setting: ${key}`);
      } else if (Array.isArray(DEFAULTS[key]) !== Array.isArray(value) || (!Array.isArray(value) && typeof value !== typeof DEFAULTS[key])) {
        errors.push(`wrong type: ${key}`);
      }
    }
    return errors;
  }

  function hostOf(url) {
    try {
      const parsed = new URL(url);
      return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.hostname : null;
    } catch {
      return null;
    }
  }

  // "*.example.com" covers example.com and every subdomain; anything else is an exact host.
  function hostMatches(host, patterns) {
    return patterns.some((pattern) =>
      pattern.startsWith("*.")
        ? host === pattern.slice(2) || host.endsWith(pattern.slice(1))
        : host === pattern,
    );
  }

  function isRootUrl(url) {
    const parsed = new URL(url);
    return parsed.pathname === "/" && !parsed.search && !parsed.hash;
  }

  // What to do with a newly opened tab that just reached `tab.url`: null to leave it, or
  // { keeper, navigate } to land in the tab already open. A tab opened from its own site was
  // opened on purpose (Duplicate Tab, a link that opens a new tab), so it stays. A hidden tab
  // belongs to a parked tab group, so it never counts as the copy to land in.
  function dedupeAction(tab, tabs, opener, config) {
    const host = hostOf(tab.url);
    if (!host || tab.hidden) return null;
    if (opener && hostOf(opener.url) === host) return null;

    const singleTab = hostMatches(host, config.singleTabHosts);
    const keeper = tabs
      .filter((other) => {
        if (other.id === tab.id || other.hidden) return false;
        return singleTab
          ? hostOf(other.url) === host
          : other.url === tab.url && other.cookieStoreId === tab.cookieStoreId;
      })
      .sort((a, b) => b.lastAccessed - a.lastAccessed)[0];
    if (!keeper) return null;

    return { keeper, navigate: tab.url !== keeper.url && !isRootUrl(tab.url) };
  }

  // One tick's work. discard frees the process and keeps the tab; sweep saves then closes;
  // close drops a tab not worth saving. Closing is capped per tick, oldest first, so a wrong
  // setting cannot empty the browser at once.
  function planTick(tabs, now, config, containerNames) {
    const plan = { discard: [], sweep: [], close: [] };
    const closing = [];

    for (const tab of tabs) {
      const host = hostOf(tab.url);
      if (!host || tab.active || tab.pinned || tab.audible) continue;

      const idle = now - tab.lastAccessed;
      const closable = !tab.hidden && !config.neverCloseContainers.includes(containerNames[tab.cookieStoreId]);
      if (closable && idle >= config.sweepDays * DAY) {
        closing.push(tab);
      } else if (!tab.discarded && idle >= config.discardHours * HOUR && !hostMatches(host, config.neverDiscardHosts)) {
        plan.discard.push(tab);
      }
    }

    closing.sort((a, b) => a.lastAccessed - b.lastAccessed);
    for (const tab of closing.slice(0, config.maxSweepPerTick)) {
      (hostMatches(hostOf(tab.url), config.closeWithoutSaving) ? plan.close : plan.sweep).push(tab);
    }
    return plan;
  }

  globalThis.TabKeeperRules = { DEFAULTS, withDefaults, configErrors, hostOf, hostMatches, dedupeAction, planTick };
})();
