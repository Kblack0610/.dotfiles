// Firefox user preferences - Debloated
// This file is read on startup and applies settings automatically
// Install: Symlink to ~/.mozilla/firefox/<profile>/user.js

// Enable userChrome.css customizations
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Smoother scrolling
user_pref("general.smoothScroll", true);

// === HARDWARE ACCELERATION ===
// GPU prefs now live in policies.json (Preferences block, Status=locked) so
// they apply on every platform without per-profile bookkeeping. Covers:
//   gfx.webrender.all, gfx.webrender.compositor,
//   media.hardware-video-decoding.force-enabled,
//   media.ffmpeg.vaapi.enabled, widget.dmabuf.force-enabled (Linux),
//   media.wmf.dxva.enabled, media.wmf.hevc.enabled (Windows).
// Linux system packages required (handled by installation_scripts/packages.conf):
//   - libva-utils         provides `vainfo`; verify with `vainfo` after install.
//   - VA-API driver       Arch: bundled in `mesa` (provides libva-mesa-driver).
//                         Debian/Ubuntu: `mesa-va-drivers` (AMD/Intel) or
//                         `libva-nvidia-driver` (NVIDIA proprietary).
// To force a specific GPU when multiple are present, export e.g.
//   LIBVA_DRIVER_NAME=radeonsi   (or nvidia / iHD / i965)

// === TELEMETRY (disable all) ===
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("browser.discovery.enabled", false);

// === POCKET (disable) ===
user_pref("extensions.pocket.enabled", false);

// === URL BAR BLOAT ===
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
user_pref("browser.urlbar.suggest.trending", false);
user_pref("browser.urlbar.suggest.recentsearches", false);
// Quick Actions: typing "manage"/"log"/"pass" surfaces a chip that opens
// about:logins on Enter — keystrokes leaking from other apps trigger it.
user_pref("browser.urlbar.suggest.quickactions", false);
user_pref("browser.urlbar.quickactions.enabled", false);
user_pref("browser.urlbar.shortcuts.quickactions", false);

// === NEW TAB BLOAT ===
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.highlights", false);
user_pref("browser.newtabpage.activity-stream.feeds.snippets", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeBookmarks", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeDownloads", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includePocket", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeVisited", false);

// === PRIVACY ===
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);

// === PASSWORD MANAGER (disable about:logins entirely) ===
// Stops "Manage Passwords" from ever opening — including stray
// keystrokes after VDI sign-out that land in the URL bar.
user_pref("signon.management.page.enabled", false);
user_pref("signon.rememberSignons", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("extensions.formautofill.creditCards.enabled", false);

// === MISC ANNOYANCES ===
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.tabs.firefox-view", false);
user_pref("identity.fxaccounts.enabled", false);

// === SESSION RESTORE ===
// Restore previous session (keeps tabs/tab groups across restarts)
user_pref("browser.startup.page", 3);

// === HOMEPAGE ===
// Used for the Home button and new windows (not new tabs — that's mozilla.cfg)
user_pref("browser.startup.homepage", "about:home");

// === TAB GROUPS ===
user_pref("browser.tabs.groups.enabled", true);

// === VDI / KEYBOARD CAPTURE ===
// 3 = PROMPT: ask the first time a site tries to override built-in
// Firefox shortcuts. Lets the VDI page capture Ctrl+W / Ctrl+T / etc.
// after a one-time accept, without globally allowing every site.
// Values: 0=UNKNOWN (default), 1=ALLOW, 2=DENY/blocks VDI, 3=PROMPT.
// Per-shortcut clearing also available at about:keyboard (Fx 147+).
user_pref("permissions.default.shortcuts", 3);
// Alt-keyup normally focuses the (hidden) menu bar, yanking keyboard focus
// out of the VDI canvas when Alt+Tab leaks through. Kill that behavior.
user_pref("ui.key.menuAccessKeyFocuses", false);

// === VERTICAL TABS (native, Firefox 136+) ===
// Moves tabs to a sidebar and natively hides the horizontal tab bar.
user_pref("sidebar.revamp", true);
user_pref("sidebar.verticalTabs", true);
// "hide-sidebar" = sidebar slides off-screen until Ctrl+B or edge hover.
// Alternatives: "always-show" (always visible), "expand-on-hover" (icons only, expand on hover).
user_pref("sidebar.visibility", "hide-sidebar");

// === DOWNLOADS (auto-save to known dir, no prompt) ===
// Lets WSL read browser-dumped console logs / saved-as files from a stable
// Windows path: C:\dev\browser-logs  →  /mnt/c/dev/browser-logs from WSL.
// Linux Firefox ignores this path silently and falls back to ~/Downloads.
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "C:\\dev\\browser-logs");
user_pref("browser.download.alwaysOpenPanel", false);
