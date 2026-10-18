// overrides/personal.js - applied on top of personal.user.js only

// Move from First Party Isolation (legacy, only maintained for Tor Browser;
// turning it on disables network partitioning and TCP) to ETP Strict =
// Total Cookie Protection + state/network partitioning.
user_pref("privacy.firstparty.isolate", false);
user_pref("browser.contentblocking.category", "strict");
user_pref("network.cookie.cookieBehavior", 5);
user_pref("network.cookie.cookieBehavior.pbmode", 5);

// No "minor issue" exceptions; keep only the baseline ones that stop major breakage
user_pref("privacy.trackingprotection.allow_list.baseline.enabled", true);
user_pref("privacy.trackingprotection.allow_list.convenience.enabled", false);

// No ETP web-compat grants (SmartBlock heuristics, automatic storage access for
// login pop-ups / redirects). Strictest; some SSO logins may need a retry.
// To undo: delete this line, then reset the pref in about:config.
user_pref("privacy.antitracking.enableWebcompat", false);
