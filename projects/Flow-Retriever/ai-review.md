# Flow Retriever - AI Code Review Document

> **How to use this file:** Paste the entire contents into your AI tool of choice. The Prompt section tells the AI what role to play and what to do. No additional context is needed.

---

## Prompt

You are a **Principal Security Engineer** with deep expertise in:
- Chrome Extension Manifest V3 architecture and security model
- Salesforce platform internals (Tooling API, SOQL, session management, Lightning Web Components SPA behaviour)
- Browser security primitives: content script isolation, cookie scoping, Clipboard API, Blob URLs, message passing security
- Common web extension vulnerabilities: SOQL injection, XSS via DOM injection, privilege escalation via untrusted messages, data exfiltration via side channels

**Your task:** Perform a comprehensive, independent code review of the Chrome Extension below. Review every file. Your output must cover:

1. **Security** - injection risks, data exposure, origin validation gaps, privilege misuse
2. **Correctness** - logic bugs, race conditions, edge cases, API misuse
3. **Performance** - memory leaks, excessive observers, unnecessary work
4. **Reliability** - error handling gaps, silent failures, MV3 service worker lifecycle issues
5. **Chrome Web Store compliance** - policy violations, permission mismatches, privacy policy accuracy

For every finding, provide:
- Severity: **Critical / Important / Minor**
- File and line reference
- Clear explanation of the risk
- A concrete fix

Be exhaustive. Do not summarise without specifics. Do not skip files.

At the end of your review, provide a final verdict:

**GO** - No Critical or Important blocking issues. The extension is ready for Chrome Web Store release.
**NO GO** - One or more Critical or Important issues must be resolved before release. List each blocker by finding number.

---

## Background

### What It Does
**Flow Retriever** is a Chrome Extension (MV3) for Salesforce Administrators. It injects a split button ("JSON | v") into the Salesforce Flow Builder canvas. When clicked, it retrieves the active Flow's metadata as raw JSON via the Salesforce Tooling API and either copies it to clipboard or downloads it as a `.json` file - without requiring Workbench, VS Code, or any other tool.

### Tech Stack
- **Manifest Version:** 3 (MV3)
- **Background:** Service worker (`scripts/background.js`)
- **Content script:** `scripts/content.js` - injected into Flow Builder pages only
- **Options page:** `options.html` + `options.js`
- **No backend.** All processing is local to the browser.
- **Permissions:** `cookies`, `storage`, `alarms`, `clipboardWrite`
- **Host permissions:** `*.salesforce.com`, `*.lightning.force.com`, `*.force.com`

### Authentication Approach
The extension reads the `sid` (Session ID) cookie from the active Salesforce tab using `chrome.cookies.getAll`. This token is used in an `Authorization: Bearer` header to call the Salesforce Tooling API. The token is never stored, logged, or transmitted anywhere other than the user's own Salesforce org.

### Key Design Decisions
| Decision | Rationale |
|---|---|
| Blob URL download in content script | `data:` URL downloads are deprecated in Chrome MV3 (Chrome 120+). Blob URL + anchor click works in content scripts without the `downloads` permission. |
| `chrome.alarms` keepalive | MV3 service workers are suspended after ~30s of inactivity. An alarm event keeps the worker alive during async Tooling API fetches. |
| Reference-counted `withKeepAlive` | Prevents alarm collision when multiple async operations are in flight simultaneously. |
| TRUSTED_ORIGINS allowlist | Cookie-derived `apiDomain` values are validated against a regex allowlist before the `sid` is ever sent to them. Bare parent domains (e.g. `salesforce.com`) are rejected. |
| URL polling (setInterval 500ms) | MV3 isolated-world content scripts cannot intercept `history.pushState` calls made by the page's JavaScript - each isolated world has its own copy of the `history` object. Polling `window.location.href` every 500ms is the correct approach without requiring the `webNavigation` permission. `popstate` listener handles browser back/forward. Hidden tab guard prevents unnecessary work in background tabs. |
| MutationObserver for modal detection | Salesforce modals overlay the canvas. The button is hidden when a modal is open so it doesn't interfere. `syncModalState()` is called once at injection to handle modals already open at init time. |
| `execCommandCopy` removed | The deprecated fallback wrote the full Flow JSON into a `<textarea>` appended to the page DOM, making it readable by third-party page scripts (ISV managed packages). Replaced with a hard error toast. |
| `sender.origin` check | `isTrustedSender` validates both `sender.tab.url` (top-level frame) and `sender.origin` (the frame that actually sent the message) to prevent spoofing via embedded iframes. |
| `301` prefix in FLOW_ID_PATTERN | Salesforce Flow record IDs always begin with `301`. Enforcing this prefix rejects IDs for other object types before any API call is made. |
| Single Tooling API call | `SELECT Id, VersionNumber, Definition.DeveloperName, Metadata FROM Flow` fetches identity and metadata in one round-trip. |
| Module-level `_defaultAction` cache | Caching the storage value at startup and keeping it live via `storage.onChanged` allows the primary button click handler to act synchronously, preserving the user-gesture window required for Clipboard API access. |
| `clipboardWrite` permission | Without this permission, `navigator.clipboard.writeText()` requires a live user-gesture activation. After an async Tooling API fetch (which can take several seconds), the activation window has expired. `clipboardWrite` allows the clipboard write to succeed regardless of activation state. |
| Broad multi-domain cookie collection | Salesforce orgs are accessed via `*.salesforce.com`, `*.my.salesforce.com`, `*.lightning.force.com`, and `*.force.com`. The TRUSTED_ORIGINS allowlist ensures only legitimate Salesforce origins receive the `sid`. |
| Hot-reload safe re-injection | `injectIntoFlowBuilder` removes any existing button before injecting a fresh one. This ensures that after extension hot-reload or auto-update, the new context's event listeners replace the stale ones from the old context. |

### Review History
The codebase has undergone two sequential human-guided review rounds, five independent parallel AI review rounds (Claude), and four additional rounds from ChatGPT, Gemini, Grok, and Vercel. The following categories of issues have already been identified and fixed:

- SOQL injection (per-field `safeId` sanitization added as defense-in-depth)
- Deprecated `data:` URL download (replaced with Blob URL)
- Nested `withKeepAlive` alarm race condition (replaced with reference-counted pattern)
- `periodInMinutes: 0.1` below Chrome's 1-minute minimum clamp (fixed to `periodInMinutes: 1`)
- Stale document click listeners across SPA navigations (fixed with `AbortController`)
- `MutationObserver` memory leak + layout thrashing (module-level ref + `disconnect()` + 150ms debounce)
- Dynamic `<style>` injection into host page DOM (moved `@keyframes` to `custom.css`)
- `history.pushState/replaceState` patching replaced with URL polling (patching only intercepts content script calls, not page JS calls, due to Chrome MV3 isolated worlds)
- `apiDomain` sent to unvalidated cookie-derived hosts (TRUSTED_ORIGINS check added)
- `execCommandCopy` DOM exposure risk (removed entirely)
- `sender.origin` fallback to `tabOrigin` when absent (now fails if `sender.origin` is missing)
- `FLOW_ID_PATTERN` allowing any object type prefix (now enforces `301`)
- `FLOW_API_NAME_PATTERN` unbounded length (capped at 80 chars)
- Filename strip regex missing control characters and Unicode RLO (added)
- `flowId` captured before async storage gap in primary button handler (moved inside callback)
- Pre-flight null `flowId` check missing (added in `triggerRetrieve`)
- 5 MB size gate on `response.json` before clipboard/download
- Retry loop stopped on 401/TypeError only - now retries all per-candidate failures (403, 404, 429, timeout)
- `getCookiesAll` ignored `chrome.runtime.lastError` (now rejects with a clear error message)
- Storage read `lastError` not checked in primary button handler (now falls back to `COPY`)
- Blob URL revoked after 5s - race condition when user has "Ask where to save" dialog (increased to 60s)
- `options.html` CSP blocked inline `<style>` (added `style-src 'self' 'unsafe-inline'`)
- `options.js` no `lastError` check on storage write (added)
- `privacy-policy.html` stale references (fully updated)
- `options.js` no `lastError` check on storage write (added)
- `privacy-policy.html` stale references (fully updated)
- Two sequential Tooling API calls merged into one (eliminates one round-trip per retrieval)
- `response.json()` unguarded - now wrapped in try/catch for malformed API response
- `collectAllSidCookies` sequential domain lookups replaced with `Promise.all` (parallel)
- Async `chrome.storage.sync.get` inside click handler expired clipboard gesture window - replaced with module-level `_defaultAction` cache + `storage.onChanged` listener
- `options.js` `storage.get` callback did not check `chrome.runtime.lastError`
- `Promise.all` in `collectAllSidCookies` was fail-fast - single domain rejection aborted entire collection (added `.catch(() => [])` per domain)
- `history.pushState/replaceState` patching was silently ineffective in isolated worlds - replaced with 500ms URL poll
- `clipboardWrite` permission missing - clipboard writes after async fetch were unreliable due to expired user-gesture activation window
- Hot-reload left stale button in DOM with dead event listeners - now always removes existing button before re-injecting
- URL poll ran in background tabs unnecessarily - added `document.hidden` guard
- Modal state not synced at injection time - `syncModalState()` now called once immediately on inject
- `_defaultAction` loaded from storage without validating against allowed values (added check)
- `storage.onChanged` listener assigned `newValue` to `_defaultAction` without `_ALLOWED_ACTIONS` validation - mirrors exact gap in initial load fix (now validates; undefined on key deletion falls back to 'COPY')
- `injectIntoFlowBuilder` had no URL guard - deferred 300ms `setTimeout` could fire after user navigated away from Flow Builder, injecting the button into a non-Flow-Builder page (URL guard added at function entry)
- `setInterval` return value was discarded - stored as `window._fxrNavInterval` and cleared on re-entry to `watchForNavigation` to prevent stale-context overlap accumulation on extension re-inject
- TDZ crash on init: module-level `let` declarations (`_modalObserver`, `_modalDebounceTimer`, `_dropdownListenerController`) were placed after the IIFE that calls `injectIntoFlowBuilder` - moved before the IIFE
- `clipboardWrite` manifest permission does not bypass Salesforce's `Permissions-Policy` for `navigator.clipboard` in content scripts - replaced with `offscreen` permission; clipboard writes now routed through an offscreen document (`offscreen.html` + `scripts/offscreen.js`) running at the extension's own origin
- Button injected before Flow Builder canvas was rendered - replaced fixed delay with `lightning-spinner` polling: two-phase poll waits for spinner to appear then disappear, adapting to any connection speed

---

## Rejected Findings

The following findings from prior review rounds were evaluated and deliberately not applied.
Do not raise these again unless the codebase has changed in a way that makes the original reasoning no longer valid.

| # | Source | Finding | Reason Rejected |
|---|---|---|---|
| R1 | ChatGPT | Restrict `host_permissions` to `activeTab` + exact origin; use `chrome.cookies.get` with a single URL instead of `getAll` | Intentional multi-domain design. Salesforce orgs are accessed via `*.salesforce.com`, `*.my.salesforce.com`, `*.lightning.force.com`, and `*.force.com`. Restricting to `activeTab` would break users on non-standard org domains. Broad `host_permissions` is required for both content script injection and background cookie reads across all Salesforce subdomains. |
| R2 | ChatGPT | Bind `apiDomainCandidate` to `orgDomain` strictly (no cross-domain session iteration) | Intentional multi-domain design. The same org can be reached under different subdomains depending on the user's browser tab URL vs. the actual API domain where the `sid` cookie lives. The TRUSTED_ORIGINS allowlist already ensures only legitimate Salesforce domains are used as API endpoints. The retry loop across candidates is a correctness requirement, not a security hole. |
| R3 | ChatGPT | Enforce strict equality between `sender.origin` and `sender.tab.url` origin (`if (sender.origin !== tabOrigin) return false`) | Would break multi-domain support. `isTrustedSender` already validates both `sender.origin` and `tabOrigin` independently against the TRUSTED_ORIGINS regex. The two values can legitimately differ when the user is on one Salesforce subdomain but the content script URL was resolved differently. |
| R4 | ChatGPT / multiple | Require user confirmation dialog before clipboard write for large payloads | Bad UX. The 5 MB size gate already prevents oversized payloads reaching clipboard. An extra confirmation dialog adds friction to the primary workflow with no meaningful security benefit. |
| R5 | ChatGPT | Restrict `host_permissions` to narrow scope for Chrome Web Store least-privilege compliance | Same as R1. Broad host permissions are necessary and justified. The store listing and privacy policy explicitly disclose the cookie access scope. This pattern is accepted for legitimate Salesforce tooling extensions. |
| R6 | ChatGPT / multiple | `versionNumber` is validated and returned but not used in the SOQL query | By design. The extension always retrieves the active/current version's metadata by Flow record ID. `versionNumber` is surfaced in the filename and returned in the response for labeling purposes only. Adding `AND VersionNumber = X` to the query would require a version selector UI that does not exist. |
| R7 | Gemini / multiple | Move `options.html` inline `<style>` to an external `options.css` file and remove `'unsafe-inline'` from CSP | Chrome Web Store accepts `'unsafe-inline'` for `style-src` on extension pages. The risk is automated scanner friction only - there is no actual security vulnerability. Moving to an external CSS file adds a new file with no functional benefit and was rejected for being low-value churn. |
| R8 | Vercel | Tighten TRUSTED_ORIGINS regex to limit subdomain depth (e.g. `{0,2}` segments) | The `$` anchor on all TRUSTED_ORIGINS patterns already prevents bypass via appended segments (e.g. `evil.salesforce.com.attacker.com` does not match because the string does not end with `.salesforce.com`). Tightening the depth could break legitimate Salesforce domains with 3+ subdomain levels (e.g. `orgname.sandbox.my.salesforce.com`). No real attack vector exists - an attacker cannot register subdomains under `salesforce.com`. |
| R9 | Vercel | Check `Content-Length` header before calling `response.json()` to guard against oversized responses | `Content-Length` is an optional HTTP header not present in chunked transfer encoding, making it an unreliable gate. The 5 MB check in content.js already prevents oversized payloads reaching the user. Adding an unreliable pre-check does not meaningfully improve safety and was rejected. |
| R10 | ChatGPT | Download via `chrome.downloads.download()` from background instead of injecting a Blob URL anchor in the page DOM | The Blob URL anchor in the DOM is the standard MV3 content script download approach and was explicitly chosen after removing `execCommandCopy`. Using `chrome.downloads` would require adding the `downloads` permission, which is a broader permission visible to users in the Web Store. The Blob URL is present in the DOM for ~100ms and the attacker would need a running MutationObserver and the ability to fetch a same-origin Blob URL within that window. Risk is accepted as negligible. |
| R11 | multiple | Add keyboard arrow/Escape navigation to the dropdown menu | Valid accessibility improvement but not a Chrome Web Store compliance blocker. Deferred as a post-release enhancement. |

---

## Code

### `manifest.json`

```json
{
  "manifest_version": 3,
  "name": "Flow Retriever",
  "version": "1.6.0",
  "description": "One-click Salesforce Flow JSON extraction directly from the browser.",
  "icons": {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  },
  "permissions": [
    "cookies",
    "storage",
    "alarms",
    "offscreen"
  ],
  "options_ui": {
    "page": "options.html",
    "open_in_tab": false
  },
  "host_permissions": [
    "*://*.salesforce.com/*",
    "*://*.lightning.force.com/*",
    "*://*.force.com/*"
  ],
  "background": {
    "service_worker": "scripts/background.js"
  },
  "content_scripts": [
    {
      "matches": [
        "*://*.salesforce.com/builder_platform_interaction/flowBuilder*",
        "*://*.lightning.force.com/builder_platform_interaction/flowBuilder*",
        "*://*.force.com/builder_platform_interaction/flowBuilder*"
      ],
      "js": ["scripts/content.js"],
      "css": ["styles/custom.css"],
      "run_at": "document_idle"
    }
  ]
}
```

---

### `scripts/background.js`

```js
const SF_API_VERSION = 'v66.0';
const FETCH_TIMEOUT_MS = 15000;
// Salesforce Flow IDs are exactly 15 or 18 chars and begin with '301'
const FLOW_ID_PATTERN = /^301[a-zA-Z0-9]{12}([a-zA-Z0-9]{3})?$/;
const FLOW_API_NAME_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]{0,79}$/;
const ALLOWED_METHODS = new Set(['COPY', 'DOWNLOAD']);
const TRUSTED_ORIGINS = [
    /^https:\/\/([a-zA-Z0-9-]+\.)+salesforce\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+lightning\.force\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+force\.com$/
];

// No-op alarm listener - the act of handling the alarm event keeps the
// service worker alive during async fetch operations in MV3.
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'sw-keepalive') {} // intentional no-op
});

// Offscreen document is used for clipboard writes. Content scripts cannot reliably
// call navigator.clipboard.writeText() on Salesforce pages because Salesforce sets
// a Permissions-Policy that blocks clipboard-write in third-party contexts.
// The offscreen document runs at the extension's own origin, bypassing that restriction.
let _offscreenCreating = null;
async function ensureOffscreen() {
    if (await chrome.offscreen.hasDocument()) return;
    if (_offscreenCreating) return _offscreenCreating;
    _offscreenCreating = chrome.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['CLIPBOARD'],
        justification: 'Write Flow JSON to clipboard from extension origin'
    }).finally(() => { _offscreenCreating = null; });
    return _offscreenCreating;
}

async function copyViaOffscreen(text) {
    const MAX_JSON_CHARS = 5 * 1024 * 1024;
    if (text.length > MAX_JSON_CHARS) throw new Error('Flow JSON exceeds 5 MB. Use Download instead.');
    await ensureOffscreen();
    return new Promise((resolve, reject) => {
        chrome.runtime.sendMessage({ action: 'COPY_TO_CLIPBOARD', text }, (response) => {
            if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
            else if (response?.success) resolve();
            else reject(new Error(response?.error || 'Clipboard write failed.'));
        });
    });
}

// Reference-counted keepalive: alarm is created on first acquire and cleared
// only when all concurrent callers have released, preventing alarm collisions.
let _keepAliveCount = 0;
function withKeepAlive(asyncFn) {
    if (++_keepAliveCount === 1) chrome.alarms.create('sw-keepalive', { periodInMinutes: 1 });
    return asyncFn().finally(() => { if (--_keepAliveCount === 0) chrome.alarms.clear('sw-keepalive'); });
}

function isTrustedSender(sender) {
    // Require both tab URL and sender.origin (frame origin in MV3).
    // Falling back to tabOrigin when sender.origin is absent would allow sandboxed
    // iframes (origin "null") to be implicitly trusted via the parent tab URL.
    if (!sender?.tab?.url || !sender.origin) return false;
    try {
        const tabOrigin = new URL(sender.tab.url).origin;
        return TRUSTED_ORIGINS.some(p => p.test(tabOrigin)) &&
               TRUSTED_ORIGINS.some(p => p.test(sender.origin));
    } catch {
        return false;
    }
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === 'RETRIEVE_FLOW') {

        if (!isTrustedSender(sender)) {
            sendResponse({ success: false, error: 'Untrusted message origin.' });
            return;
        }

        const orgDomain = new URL(sender.tab.url).origin;
        const { flowApiName, flowId, versionNumber, method } = request;

        if (!ALLOWED_METHODS.has(method)) {
            sendResponse({ success: false, error: 'Invalid method.' });
            return;
        }
        if (!flowApiName && !flowId) {
            sendResponse({ success: false, error: 'Flow API Name or ID is required.' });
            return;
        }
        if (flowApiName && !FLOW_API_NAME_PATTERN.test(flowApiName)) {
            sendResponse({ success: false, error: 'Invalid Flow API Name.' });
            return;
        }
        if (flowId && !FLOW_ID_PATTERN.test(flowId)) {
            sendResponse({ success: false, error: 'Invalid Flow ID.' });
            return;
        }
        if (versionNumber !== null && versionNumber !== undefined) {
            const v = Number(versionNumber);
            if (!Number.isInteger(v) || v < 1) {
                sendResponse({ success: false, error: 'Invalid version number.' });
                return;
            }
        }

        // Single withKeepAlive wraps the entire async chain to avoid nested alarm collisions
        withKeepAlive(async () => {
            const candidates = await collectAllSidCookies(orgDomain);
            if (!candidates.length) {
                sendResponse({ success: false, error: 'No active Salesforce session found. Please ensure you are logged in.' });
                return;
            }

            let lastError = 'All session candidates failed.';

            for (const { sessionId, apiDomain } of candidates) {
                try {
                    const result = await fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber);
                    if (method === 'COPY') {
                        await copyViaOffscreen(result.json);
                        sendResponse({ success: true, flowApiName: result.flowApiName, versionNumber: result.versionNumber });
                    } else {
                        sendResponse({ success: true, json: result.json, flowApiName: result.flowApiName, versionNumber: result.versionNumber });
                    }
                    return;
                } catch (error) {
                    // Only abort the loop for input-validation errors that will not change
                    // across candidates (e.g. structurally invalid Flow ID).
                    // All per-candidate failures (401, 403, 404, 429, timeout, network error)
                    // are retried with the next candidate session.
                    if (error.message.startsWith('A valid Flow ID')) {
                        sendResponse({ success: false, error: error.message });
                        return;
                    }
                    lastError = error.message;
                    continue;
                }
            }

            sendResponse({ success: false, error: lastError });
        }).catch((error) => {
            sendResponse({ success: false, error: error.message });
        });

        return true;
    }
});

function getCookiesAll(details) {
    return new Promise((resolve, reject) => chrome.cookies.getAll(details, (cookies) => {
        if (chrome.runtime.lastError) {
            reject(new Error(`Unable to read Salesforce session cookies: ${chrome.runtime.lastError.message}`));
        } else {
            resolve(cookies);
        }
    }));
}

async function collectAllSidCookies(orgDomain) {
    const hostname = new URL(orgDomain).hostname;

    const domainRoots = new Set();
    for (const suffix of ['.lightning.force.com', '.my.salesforce.com', '.salesforce.com', '.force.com']) {
        if (hostname.endsWith(suffix)) {
            const base = hostname.slice(0, hostname.length - suffix.length);
            domainRoots.add(`${base}.salesforce.com`);
            domainRoots.add(`${base}.my.salesforce.com`);
            domainRoots.add(`${base}.lightning.force.com`);
            domainRoots.add(`${base}.force.com`);
        }
    }
    domainRoots.add(hostname);

    // Fetch all domains in parallel; individual failures resolve to [] so one bad
    // domain does not abort the entire collection via Promise.all's fail-fast behaviour.
    const allCookies = await Promise.all(
        [...domainRoots].map(domain => getCookiesAll({ domain, name: 'sid' }).catch(() => []))
    );

    const seen = new Set();
    const results = [];

    for (const cookies of allCookies) {
        for (const c of cookies) {
            if (c.value && !seen.has(c.value)) {
                seen.add(c.value);
                const cookieHost = c.domain.startsWith('.') ? c.domain.slice(1) : c.domain;
                const apiDomainCandidate = `https://${cookieHost}`;
                // Only use cookie domains that match a known Salesforce origin pattern;
                // bare parent domains (e.g. salesforce.com) are rejected here rather than
                // sending the sid to an unvalidated host and relying on a network error retry.
                if (!TRUSTED_ORIGINS.some(p => p.test(apiDomainCandidate))) continue;
                results.push({ sessionId: c.value, apiDomain: apiDomainCandidate });
            }
        }
    }
    return results;
}

// Single Tooling API call returns identity fields + metadata in one round-trip
async function fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber) {
    if (!flowId || !FLOW_ID_PATTERN.test(flowId)) throw new Error('A valid Flow ID is required.');

    // Secondary sanitization before interpolation - defense in depth
    const safeId = flowId.replace(/[^a-zA-Z0-9]/g, '');
    const query = `SELECT Id, VersionNumber, Definition.DeveloperName, Metadata FROM Flow WHERE Id = '${safeId}'`;
    const url = `${apiDomain}/services/data/${SF_API_VERSION}/tooling/query/?q=${encodeURIComponent(query)}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    let response;
    try {
        response = await fetch(url, {
            headers: { 'Authorization': `Bearer ${sessionId}` },
            signal: controller.signal
        });
    } catch (err) {
        if (err.name === 'AbortError') throw new Error('Request timed out after 15 seconds.');
        throw err;
    } finally {
        clearTimeout(timeoutId);
    }

    if (!response.ok) {
        const err = new Error(`Salesforce API Error: ${response.status} ${response.statusText}`);
        err.cause = response.status;
        throw err;
    }

    let jsonResponse;
    try {
        jsonResponse = await response.json();
    } catch {
        throw new Error('Salesforce API returned malformed JSON.');
    }

    if (!jsonResponse.records || jsonResponse.records.length === 0) {
        throw new Error(`Flow "${flowId}" (Version ${versionNumber ?? 'Active'}) not found in this org.`);
    }

    const record = jsonResponse.records[0];
    const metadata = record.Metadata;

    // Explicit null check - missing metadata means a permissions problem, not a missing flow
    if (metadata == null) {
        throw new Error(`Flow "${flowId}" returned no metadata. Check org permissions.`);
    }

    const resolvedApiName = record.Definition?.DeveloperName || null;
    const ver = record.VersionNumber ?? (versionNumber != null ? Number(versionNumber) : null);

    let filename = resolvedApiName;
    if (!filename && metadata.label) {
        // Strip invalid filename chars, dots (prevents .. sequences), control characters,
        // and Unicode direction overrides (‮) and zero-width chars (​) to
        // prevent filename spoofing attacks.
        filename = metadata.label.replace(/\s+/g, '_').replace(/[\\/:*?"<>|.\x00-\x1f‮​]/g, '');
    }

    return {
        json: JSON.stringify(metadata, null, 2),
        flowApiName: filename || flowId,
        versionNumber: ver
    };
}
```

---

### `scripts/content.js`

```js
// ==========================================
// TOAST NOTIFICATION SYSTEM
// ==========================================
function showToast(message, type = 'info') {
    const COLORS = {
        success: { bg: '#2e844a', icon: '✓' },
        error:   { bg: '#ba0517', icon: '✕' },
        info:    { bg: '#0070d2', icon: 'ℹ' }
    };
    const { bg, icon } = COLORS[type] || COLORS.info;

    const toast = document.createElement('div');
    toast.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        z-index: 99999;
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 12px 16px;
        background: ${bg};
        color: #fff;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        font-size: 13px;
        font-weight: 500;
        border-radius: 4px;
        box-shadow: 0 4px 12px rgba(0,0,0,0.25);
        max-width: 360px;
        line-height: 1.4;
        animation: fxr-slide-in 0.2s ease-out;
        pointer-events: none;
    `;

    // Animations are defined in styles/custom.css (injected by the extension),
    // avoiding dynamic <style> injection into the host page DOM.

    const iconEl = document.createElement('span');
    iconEl.style.cssText = 'font-size:15px;flex-shrink:0;';
    iconEl.textContent = icon;

    const textEl = document.createElement('span');
    textEl.textContent = message;

    toast.appendChild(iconEl);
    toast.appendChild(textEl);
    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.animation = 'fxr-fade-out 0.3s ease-in forwards';
        setTimeout(() => toast.remove(), 300);
    }, type === 'error' ? 6000 : 3000);
}

// ==========================================
// CLIPBOARD HELPER
// Uses the async Clipboard API only. execCommand('copy') was removed because
// it writes the full Flow JSON into the page DOM where other page scripts
// (e.g. ISV managed package JS) can read it during the operation.
// If the Clipboard API is unavailable, the caller surfaces an error toast.
// ==========================================
function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        return navigator.clipboard.writeText(text);
    }
    return Promise.reject(new Error('Clipboard API unavailable'));
}

// ==========================================
// DOWNLOAD HELPER
// Blob URL + anchor click is the correct approach for content scripts in MV3 (Chrome 120+).
// ==========================================
function downloadJson(jsonContent, flowApiName, versionNumber) {
    const filename = `${flowApiName}_Ver${versionNumber ?? 'Active'}.json`;
    const blob = new Blob([jsonContent], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.style.cssText = 'display:none;position:fixed;';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    // 60s delay: if the user has "Ask where to save" enabled in Chrome, the OS file
    // dialog stays open and the download reads the Blob URL after the click. Revoking
    // at 5s destroys the URL before they finish navigating the dialog.
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    showToast(`Downloaded: ${filename}`, 'success');
}

// ==========================================
// ENTRY POINT
// ==========================================
(function init() {
    if (window.location.href.includes('/builder_platform_interaction/flowBuilder')) {
        injectIntoFlowBuilder();
        watchForNavigation();
    }
})();

// Module-level references for cleanup across SPA navigations
let _modalObserver = null;
let _modalDebounceTimer = null;
let _dropdownListenerController = null;

// Cache defaultAction so the click handler can act synchronously - the async
// storage.sync.get callback expires the user-gesture window needed for clipboard access.
const _ALLOWED_ACTIONS = new Set(['COPY', 'DOWNLOAD']);
let _defaultAction = 'COPY';
chrome.storage.sync.get({ defaultAction: 'COPY' }, (result) => {
    if (!chrome.runtime.lastError && result?.defaultAction) {
        _defaultAction = _ALLOWED_ACTIONS.has(result.defaultAction) ? result.defaultAction : 'COPY';
    }
});
chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'sync' && changes.defaultAction) {
        const nv = changes.defaultAction.newValue;
        _defaultAction = _ALLOWED_ACTIONS.has(nv) ? nv : 'COPY';
    }
});

// Polls until the Flow Builder loading spinner (lightning-spinner) has appeared and then
// disappeared, indicating the canvas is ready. Two-phase: first waits for the spinner
// to appear (it may not exist yet when the content script runs), then for it to go.
// Falls back after 30s for slow orgs. MutationObserver cannot be used here because
// Salesforce renders the spinner inside shadow DOM, which MutationObserver cannot observe.
function waitForFlowCanvas(callback) {
    const TIMEOUT_MS = 30000;
    const start = Date.now();
    let spinnerSeen = !!document.querySelector('lightning-spinner');

    const interval = setInterval(() => {
        const spinner = !!document.querySelector('lightning-spinner');

        if (!spinnerSeen && spinner) {
            spinnerSeen = true;
        } else if (spinnerSeen && !spinner) {
            clearInterval(interval);
            callback();
            return;
        }

        if (Date.now() - start >= TIMEOUT_MS) {
            clearInterval(interval);
            callback();
        }
    }, 500);
}

// ==========================================
// ENTRY POINT
// ==========================================
(function init() {
    if (window.location.href.includes('/builder_platform_interaction/flowBuilder')) {
        waitForFlowCanvas(injectIntoFlowBuilder);
        watchForNavigation();
    }
})();

// ==========================================
// SPA navigation watcher
// Polls window.location.href every 500ms. pushState/replaceState patching does not
// work in MV3 isolated worlds (each world has its own history object).
// Guard against interval accumulation on extension hot-reload via _fxrNavPatched flag.
// ==========================================
function watchForNavigation() {
    // Clear any prior interval from a stale context before starting a new one
    if (window._fxrNavInterval) { clearInterval(window._fxrNavInterval); window._fxrNavInterval = null; }
    if (window._fxrNavPatched) return;
    window._fxrNavPatched = true;

    let lastUrl = window.location.href;

    const handleNavigation = () => {
        if (document.hidden) return; // No work needed while tab is not visible
        const currentUrl = window.location.href;
        // Skip if URL has not meaningfully changed
        if (currentUrl === lastUrl) return;
        lastUrl = currentUrl;

        const existing = document.querySelector('#xml-retrieve-builder-btn');
        if (existing) {
            // Disconnect observer and cancel any pending debounce before removing the element
            if (_modalObserver) { _modalObserver.disconnect(); _modalObserver = null; }
            if (_modalDebounceTimer) { clearTimeout(_modalDebounceTimer); _modalDebounceTimer = null; }
            existing.remove();
        }

        if (currentUrl.includes('/builder_platform_interaction/flowBuilder')) {
            waitForFlowCanvas(injectIntoFlowBuilder);
        }
    };

    // Poll for URL changes every 500ms - the only reliable SPA detection approach
    // in MV3 isolated-world content scripts (pushState/replaceState patching only
    // intercepts calls from the content script's own world, not the page's JS).
    window._fxrNavInterval = setInterval(handleNavigation, 500);
    window.addEventListener('popstate', handleNavigation);
}

// ==========================================
// SHARED: Send message to background and handle response
// ==========================================
function triggerRetrieve(method, flowId) {
    if (!flowId) {
        showToast('Flow ID not found in URL. Please ensure a Flow is open.', 'error');
        return;
    }

    chrome.runtime.sendMessage(
        { action: 'RETRIEVE_FLOW', method, flowApiName: null, versionNumber: null, flowId },
        (response) => {
            if (chrome.runtime.lastError) {
                showToast(chrome.runtime.lastError.message, 'error');
                return;
            }
            if (!response || !response.success) {
                showToast(response?.error || 'Unknown error', 'error');
                return;
            }
            if (method === 'COPY') {
                // Clipboard write handled by background via offscreen document
                showToast('Flow JSON copied to clipboard.', 'success');
            } else if (method === 'DOWNLOAD') {
                downloadJson(response.json, response.flowApiName, response.versionNumber);
            }
        }
    );
}

// ==========================================
// ENVIRONMENT: Flow Builder Canvas
// ==========================================
function injectIntoFlowBuilder() {
    // Guard: deferred setTimeout calls can fire after the user has already navigated away.
    if (!window.location.href.includes('/builder_platform_interaction/flowBuilder')) return;
    // Remove any stale button from a previous extension context (hot-reload / auto-update).
    // Returning early would leave the old button whose event listeners point to the dead context.
    const existing = document.querySelector('#xml-retrieve-builder-btn');
    if (existing) existing.remove();

    const wrapper = document.createElement('div');
    wrapper.id = 'xml-retrieve-builder-btn';

    const primaryBtn = document.createElement('button');
    primaryBtn.id = 'xml-retrieve-btn-primary';
    primaryBtn.textContent = 'JSON';
    primaryBtn.title = 'Execute default action (configurable in extension options)';
    primaryBtn.addEventListener('click', () => {
        const { flowId } = resolveFlowIdentityFromBuilder();
        triggerRetrieve(_defaultAction, flowId);
    });

    const arrowBtn = document.createElement('button');
    arrowBtn.id = 'xml-retrieve-btn-arrow';
    arrowBtn.textContent = '▼';
    arrowBtn.title = 'JSON options';
    arrowBtn.setAttribute('aria-haspopup', 'true');
    arrowBtn.setAttribute('aria-expanded', 'false');

    const dropdownMenu = document.createElement('div');
    dropdownMenu.id = 'xml-retrieve-builder-menu';
    dropdownMenu.setAttribute('role', 'menu');
    dropdownMenu.setAttribute('aria-label', 'JSON export options');

    const menuList = document.createElement('ul');
    menuList.className = 'slds-dropdown__list';

    const makeMenuItem = (label, method) => {
        const li = document.createElement('li');
        li.setAttribute('role', 'presentation');
        const a = document.createElement('a');
        a.href = '#';
        a.setAttribute('role', 'menuitem');
        a.textContent = label;
        a.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            closeDropdown();
            const { flowId } = resolveFlowIdentityFromBuilder();
            triggerRetrieve(method, flowId);
        });
        li.appendChild(a);
        return li;
    };

    menuList.appendChild(makeMenuItem('📋  Copy JSON', 'COPY'));
    menuList.appendChild(makeMenuItem('⬇  Download JSON', 'DOWNLOAD'));
    dropdownMenu.appendChild(menuList);

    const closeDropdown = () => {
        dropdownMenu.style.display = 'none';
        arrowBtn.setAttribute('aria-expanded', 'false');
    };

    arrowBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        const isOpen = dropdownMenu.style.display === 'block';
        dropdownMenu.style.display = isOpen ? 'none' : 'block';
        arrowBtn.setAttribute('aria-expanded', String(!isOpen));
    });

    // AbortController ensures the previous document listener is removed before re-injecting,
    // preventing accumulation of stale capture listeners across SPA navigations
    if (_dropdownListenerController) _dropdownListenerController.abort();
    _dropdownListenerController = new AbortController();
    document.addEventListener('click', (e) => {
        if (!wrapper.contains(e.target)) closeDropdown();
    }, { capture: true, signal: _dropdownListenerController.signal });

    wrapper.appendChild(primaryBtn);
    wrapper.appendChild(arrowBtn);
    wrapper.appendChild(dropdownMenu);
    document.body.appendChild(wrapper);

    // Debounced MutationObserver: Salesforce Flow Builder mutates the DOM hundreds of
    // times per second (drag, type, hover). Running querySelector on every mutation
    // causes layout thrashing. The 150ms debounce coalesces bursts into one check.
    let lastModalState = false;
    const syncModalState = () => {
        const modalOpen = !!document.querySelector('.modal-backdrop, .slds-backdrop_open');
        if (modalOpen !== lastModalState) {
            lastModalState = modalOpen;
            wrapper.style.display = modalOpen ? 'none' : 'flex';
        }
    };

    syncModalState(); // Sync immediately - modal may already be open at injection time

    _modalObserver = new MutationObserver(() => {
        if (_modalDebounceTimer) return;
        _modalDebounceTimer = setTimeout(() => {
            _modalDebounceTimer = null;
            syncModalState();
        }, 150);
    });
    _modalObserver.observe(document.body, { childList: true, subtree: true });
}

// Returns flowId from URL query params - resolved at call time to handle SPA navigation
function resolveFlowIdentityFromBuilder() {
    const params = new URLSearchParams(window.location.search);
    const flowId = params.get('flowId') || params.get('id') || null;
    return { flowId };
}
```

---

### `options.js`

```js
const ALLOWED_ACTIONS = new Set(['COPY', 'DOWNLOAD']);
const radios = document.querySelectorAll('input[name="defaultAction"]');
const status = document.getElementById('status');

chrome.storage.sync.get({ defaultAction: 'COPY' }, (result) => {
    const defaultAction = chrome.runtime.lastError ? 'COPY' : (result?.defaultAction ?? 'COPY');
    const safeDefault = ALLOWED_ACTIONS.has(defaultAction) ? defaultAction : 'COPY';
    if (!chrome.runtime.lastError && safeDefault !== defaultAction) {
        chrome.storage.sync.set({ defaultAction: safeDefault });
    }
    radios.forEach(r => { r.checked = r.value === safeDefault; });
});

radios.forEach(radio => {
    radio.addEventListener('change', () => {
        if (!ALLOWED_ACTIONS.has(radio.value)) return;
        chrome.storage.sync.set({ defaultAction: radio.value }, () => {
            if (!status) return;
            if (chrome.runtime.lastError) {
                status.textContent = 'Save failed.';
            } else {
                status.textContent = 'Saved.';
            }
            setTimeout(() => { if (status) status.textContent = ''; }, 1500);
        });
    });
});
```

---

### `options.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'">
    <title>Flow Retriever - Options</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            font-size: 13px;
            color: #3e3e3c;
            padding: 1.5rem 2rem;
            min-width: 280px;
            max-width: 400px;
        }
        h2 {
            font-size: 14px;
            font-weight: 600;
            margin: 0 0 1rem;
            color: #080707;
        }
        .setting-group {
            margin-bottom: 1.25rem;
        }
        .setting-label {
            font-weight: 600;
            margin-bottom: 0.5rem;
            display: block;
        }
        label {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            padding: 0.3rem 0;
            cursor: pointer;
        }
        #status {
            font-size: 12px;
            color: #2e844a;
            height: 1.2em;
            margin-top: 0.5rem;
        }
    </style>
</head>
<body>
    <h2>Flow Retriever Settings</h2>

    <div class="setting-group">
        <span class="setting-label">Default action when clicking JSON</span>
        <label>
            <input type="radio" name="defaultAction" value="COPY">
            📋 Copy to clipboard
        </label>
        <label>
            <input type="radio" name="defaultAction" value="DOWNLOAD">
            ⬇ Download file
        </label>
    </div>

    <div id="status"></div>

    <script src="options.js"></script>
</body>
</html>
```

---

### `styles/custom.css`

```css
/* --- FLOW RETRIEVER: CUSTOM STYLES --- */

/* Toast animations - defined here so content.js does not inject <style> into the host DOM */
@keyframes fxr-slide-in { from { opacity:0; transform:translateX(20px); } to { opacity:1; transform:translateX(0); } }
@keyframes fxr-fade-out { from { opacity:1; } to { opacity:0; transform:translateY(-6px); } }

/* Flow Builder: Fixed-position split button, top-right, clear of the ? help icon */
#xml-retrieve-builder-btn {
    position: fixed;
    top: 6px;
    right: 110px;
    z-index: 9999;
    display: flex;
    align-items: stretch;
    border: 1px solid #c9c7c5;
    border-radius: 0.25rem;
    overflow: visible;
    box-shadow: 0 1px 2px rgba(0,0,0,0.1);
}

#xml-retrieve-btn-primary {
    padding: 0 0.6rem;
    font-size: 0.75rem;
    font-weight: 600;
    background: #fff;
    color: #3e3e3c;
    border: none;
    cursor: pointer;
    line-height: 1.875rem;
    letter-spacing: 0.03em;
}

#xml-retrieve-btn-primary:hover {
    background: #f3f3f3;
}

#xml-retrieve-btn-arrow {
    padding: 0 0.4rem;
    font-size: 0.55rem;
    background: #fff;
    color: #3e3e3c;
    border: none;
    border-left: 1px solid #c9c7c5;
    cursor: pointer;
    line-height: 1.875rem;
}

#xml-retrieve-btn-arrow:hover {
    background: #f3f3f3;
}

#xml-retrieve-builder-menu {
    display: none;
    position: absolute;
    top: calc(100% + 4px);
    right: 0;
    z-index: 10000;
    background: #fff;
    border: 1px solid #dddbda;
    border-radius: 0.25rem;
    box-shadow: 0 2px 6px rgba(0,0,0,0.16);
    min-width: 10rem;
    padding: 0.25rem 0;
    list-style: none;
    margin: 0;
}

#xml-retrieve-builder-menu .slds-dropdown__list {
    list-style: none;
    margin: 0;
    padding: 0;
}

#xml-retrieve-builder-menu a {
    display: block;
    padding: 0.45rem 1rem;
    color: #080707;
    text-decoration: none;
    font-size: 0.8125rem;
    white-space: nowrap;
}

#xml-retrieve-builder-menu a:hover {
    background: #f3f3f3;
}
```
