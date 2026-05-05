// Bootstraps Firefox to read /usr/lib/firefox/mozilla.cfg at startup.
// Installed to /usr/lib/firefox/defaults/pref/autoconfig.js by install.sh.
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
pref("general.config.sandbox_enabled", false);
