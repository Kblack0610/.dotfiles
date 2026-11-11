// Tab Keeper decisions, free of browser APIs so tests/tab-keeper can run them in node.
// background.js does what these return. Host names and thresholds are config, never code.
(() => {
  const DEFAULTS = {
    dryRun: true,
    discardHours: 2,
    sweepDays: 7,
    homeSetSweepHours: 4,
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

  // Settings and key come only from the Firefox policy (3rdparty.Extensions in policies.json, built
  // by install.sh). Anything wrong there falls back to defaults, which are dry run, and names why.
  function fromPolicy(policy) {
    if (!policy?.config) return { config: withDefaults({}), problem: "no settings in the Firefox policy: rerun install.sh" };
    const errors = configErrors(policy.config);
    if (errors.length) return { config: withDefaults({}), problem: `policy settings: ${errors.join("; ")}` };
    const config = withDefaults(policy.config);
    const key = policy.karakeepKey || "";
    if (config.karakeepUrl && !key) return { config, key, problem: "no Karakeep key in the Firefox policy: rbw unlock, rerun install.sh" };
    return { config, key, problem: null };
  }

  // Firefox match patterns carry no port, so this is built from the hostname, not the origin.
  function karakeepOrigin(url) {
    const { protocol, hostname } = new URL(url);
    return `${protocol}//${hostname}/*`;
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

  // A profile whose home page lists web pages has a home set: those tabs stay pinned and open, and
  // every other tab is swept after homeSetSweepHours instead of sweepDays. "about:home" gives none.
  function homeSetFrom(homepage) {
    return (homepage ?? "").split("|").map((url) => url.trim()).filter((url) => hostOf(url));
  }

  const pageOf = (url) => {
    const { origin, pathname } = new URL(url);
    return origin + pathname;
  };

  // Which home tabs to pin and which to open. A pinned tab may have navigated within its site
  // (a calendar week, a device page), so on each host every pinned tab counts toward that host's
  // home pages and only the shortfall is filled: first by pinning an open copy, then by opening
  // one. Hidden tabs belong to a parked group and do not count.
  function homeSetAction(home, tabs) {
    const visible = tabs.filter((tab) => !tab.hidden && hostOf(tab.url));
    const pin = [];
    const open = [];
    for (const host of new Set(home.map(hostOf))) {
      const pages = [...new Set(home.filter((url) => hostOf(url) === host))];
      const onHost = visible.filter((tab) => hostOf(tab.url) === host);
      const copies = (url) => onHost.filter((tab) => pageOf(tab.url) === pageOf(url)).sort((a, b) => b.lastAccessed - a.lastAccessed);
      let shortfall = pages.length - onHost.filter((tab) => tab.pinned).length;
      const unmet = pages.filter((url) => !copies(url).some((tab) => tab.pinned));
      for (const url of unmet) {
        if (shortfall <= 0) break;
        const copy = copies(url).find((tab) => !pin.includes(tab));
        if (copy) pin.push(copy);
        else open.push(url);
        shortfall -= 1;
      }
    }
    return { pin, open };
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
  // In a home-set profile a tab sweeps after homeSetSweepHours; pinned tabs and home pages never sweep.
  function planTick(tabs, now, config, containerNames, home = []) {
    const plan = { discard: [], sweep: [], close: [] };
    const closing = [];
    const sweepAfter = home.length ? config.homeSetSweepHours * HOUR : config.sweepDays * DAY;
    const homePages = new Set(home.map(pageOf));

    for (const tab of tabs) {
      const host = hostOf(tab.url);
      if (!host || tab.active || tab.pinned || tab.audible) continue;

      const idle = now - tab.lastAccessed;
      const closable = !tab.hidden && !homePages.has(pageOf(tab.url)) && !config.neverCloseContainers.includes(containerNames[tab.cookieStoreId]);
      if (closable && idle >= sweepAfter) {
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

  globalThis.TabKeeperRules = { DEFAULTS, withDefaults, configErrors, fromPolicy, karakeepOrigin, hostOf, hostMatches, homeSetFrom, homeSetAction, dedupeAction, planTick };
})();
