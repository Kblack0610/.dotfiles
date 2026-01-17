// Firefox user preferences
// This file is read on startup and applies settings automatically
// Install: Copy to ~/.mozilla/firefox/<profile>/user.js

// Enable userChrome.css customizations
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Smoother scrolling
user_pref("general.smoothScroll", true);

// Disable pocket (sidebar clutter)
user_pref("extensions.pocket.enabled", false);

// Disable sponsored content on new tab
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);

// Privacy improvements
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
