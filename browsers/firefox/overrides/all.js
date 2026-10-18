// overrides/all.js - applied on top of EVERY exported Firefox profile
// (firefox-export-userjs.sh merges it; these values win over the profile)

// Safe Browsing: no remote lookup for downloads. Sends name, origin, size and
// hash of every downloaded file to Google. Local list checks stay on.
user_pref("browser.safebrowsing.downloads.remote.enabled", false);
user_pref("browser.safebrowsing.downloads.remote.url", "");
