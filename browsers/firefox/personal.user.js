// user.js - exported as-is from my hardened Firefox profile
// generated 2026-10-18 by browsers/firefox/firefox-export-userjs.sh
// install: copy into a profile folder (about:profiles -> Root Directory), restart Firefox
// only settings - no paths, URLs, domains or IDs
// overrides merged: overrides/all.js (2), overrides/personal.js (7)

// --- telemetry / studies
user_pref("app.normandy.enabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("breakpad.reportURL", "");
user_pref("browser.discovery.enabled", false);
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.usage.uploadEnabled", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);

// --- AI
user_pref("browser.ai.control.default", "blocked");
user_pref("browser.ai.control.linkPreviewKeyPoints", "blocked");
user_pref("browser.ai.control.pdfjsAltText", "blocked");
user_pref("browser.ai.control.sidebarChatbot", "blocked");
user_pref("browser.ai.control.smartTabGroups", "blocked");
user_pref("browser.ai.control.translations", "blocked");
user_pref("browser.ml.chat.enabled", false);
user_pref("browser.ml.chat.page", false);
user_pref("browser.ml.linkPreview.enabled", false);
user_pref("browser.translations.enable", false);

// --- tracking / fingerprinting
user_pref("browser.contentblocking.category", "strict");
user_pref("dom.event.clipboardevents.enabled", false);
user_pref("privacy.annotate_channels.strict_list.enabled", true);
user_pref("privacy.antitracking.enableWebcompat", false);
user_pref("privacy.antitracking.isolateContentScriptResources", true);
user_pref("privacy.bounceTrackingProtection.mode", 1);
user_pref("privacy.clearHistory.formdata", true);
user_pref("privacy.clearOnShutdown_v2.browsingHistoryAndDownloads", false);
user_pref("privacy.clearOnShutdown_v2.formdata", true);
user_pref("privacy.fingerprintingProtection", true);
user_pref("privacy.firstparty.isolate", false);
user_pref("privacy.globalprivacycontrol.enabled", true);
user_pref("privacy.query_stripping.enabled", true);
user_pref("privacy.query_stripping.enabled.pbmode", true);
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.block_mozAddonManager", true);
user_pref("privacy.resistFingerprinting.exemptedDomains", "");
user_pref("privacy.resistFingerprinting.pbmode", true);
user_pref("privacy.sanitize.sanitizeOnShutdown", true);
user_pref("privacy.spoof_english", 1);
user_pref("privacy.trackingprotection.allow_list.baseline.enabled", true);
user_pref("privacy.trackingprotection.allow_list.convenience.enabled", false);
user_pref("privacy.trackingprotection.consentmanager.skip.pbmode.enabled", false);
user_pref("privacy.trackingprotection.emailtracking.enabled", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.window.maxInnerWidth", 1600);
user_pref("webgl.disabled", true);

// --- cookies
user_pref("network.cookie.cookieBehavior", 5);
user_pref("network.cookie.cookieBehavior.pbmode", 5);
user_pref("network.cookie.cookieBehavior.trackerCookieBlocking", true);

// --- WebRTC / media / permissions
user_pref("geo.enabled", false);
user_pref("geo.provider.use_geoclue", false);
user_pref("media.memory_cache_max_size", 3192);
user_pref("media.navigator.enabled", false);
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);
user_pref("media.peerconnection.ice.proxy_only_if_behind_proxy", true);
user_pref("permissions.default.camera", 2);
user_pref("permissions.default.local-network", 2);
user_pref("permissions.default.microphone", 2);

// --- HTTPS / TLS
user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_send_http_background_request", false);
user_pref("security.cert_pinning.enforcement_level", 2);
user_pref("security.csp.reporting.enabled", false);
user_pref("security.ssl.require_safe_negotiation", true);
user_pref("security.ssl.treat_unsafe_negotiation_as_broken", true);
user_pref("security.tls.enable_0rtt_data", false);

// --- network / prefetch / DNS
user_pref("browser.places.speculativeConnect.enabled", false);
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("captivedetect.canonicalURL", "");
user_pref("network.auth.subresource-http-auth-allow", 1);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.file.disable_unc_paths", true);
user_pref("network.gio.supported-protocols", "");
user_pref("network.http.referer.disallowCrossSiteRelaxingDefault.top_navigation", true);
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.predictor.enabled", false);
user_pref("network.prefetch-next", false);

// --- search / URL bar / new tab
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredCheckboxes", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.urlbar.suggest.engines", false);
user_pref("browser.urlbar.suggest.openpage", false);
user_pref("browser.urlbar.suggest.quickactions", false);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.topsites", false);

// --- passwords / forms
user_pref("browser.formfill.enable", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("extensions.formautofill.creditCards.enabled", false);
user_pref("signon.autofillForms", false);
user_pref("signon.firefoxRelay.feature", "disabled");
user_pref("signon.formlessCapture.enabled", false);
user_pref("signon.rememberSignons", false);

// --- other
user_pref("browser.cache.disk.enable", false);
user_pref("browser.download.always_ask_before_handling_new_types", true);
user_pref("browser.download.manager.addToRecentDocs", false);
user_pref("browser.download.start_downloads_in_tmp_dir", true);
user_pref("browser.download.useDownloadDir", false);
user_pref("browser.privatebrowsing.autostart", true);
user_pref("browser.privatebrowsing.forceMediaMemoryCache", true);
user_pref("browser.safebrowsing.downloads.remote.enabled", false);
user_pref("browser.safebrowsing.downloads.remote.url", "");
user_pref("browser.sessionstore.privacy_level", 2);
user_pref("dom.disable_window_move_resize", true);
user_pref("dom.forms.autocomplete.formautofill", true);
user_pref("extensions.postDownloadThirdPartyPrompt", false);
user_pref("pdfjs.enableScripting", false);
