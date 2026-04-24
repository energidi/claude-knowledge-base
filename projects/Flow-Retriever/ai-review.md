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
- **Permissions:** `cookies`, `storage`, `alarms`
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
| `history.pushState` + `replaceState` patching | Salesforce Flow Builder is a full SPA. Both methods are patched to detect navigation and re-inject/remove the button. |
| MutationObserver for modal detection | Salesforce modals overlay the canvas. The button is hidden when a modal is open so it doesn't interfere. |
| `execCommandCopy` removed | The deprecated fallback wrote the full Flow JSON into a `<textarea>` appended to the page DOM, making it readable by third-party page scripts (ISV managed packages). Replaced with a hard error toast. |
| `sender.origin` check | `isTrustedSender` validates both `sender.tab.url` (top-level frame) and `sender.origin` (the frame that actually sent the message) to prevent spoofing via embedded iframes. |
| `301` prefix in FLOW_ID_PATTERN | Salesforce Flow record IDs always begin with `301`. Enforcing this prefix rejects IDs for other object types before any API call is made. |

### Review History
The codebase has undergone two sequential human-guided review rounds plus five independent parallel AI review rounds. The following categories of issues have already been identified and fixed:

- SOQL injection (per-field `safeId` sanitization added as defense-in-depth)
- Deprecated `data:` URL download (replaced with Blob URL)
- Nested `withKeepAlive` alarm race condition (replaced with reference-counted pattern)
- Stale document click listeners across SPA navigations (fixed with `AbortController`)
- `MutationObserver` memory leak across SPA navigations (fixed with module-level ref + `disconnect()`)
- `history.replaceState` not patched (now patched alongside `pushState`)
- `apiDomain` sent to unvalidated cookie-derived hosts (TRUSTED_ORIGINS check added)
- `execCommandCopy` DOM exposure risk (removed entirely)
- `sender.origin` not checked (now validated in `isTrustedSender`)
- `FLOW_ID_PATTERN` allowing any object type prefix (now enforces `301`)
- `FLOW_API_NAME_PATTERN` unbounded length (capped at 80 chars)
- Filename strip regex missing control characters and Unicode RLO (added)
- `flowId` captured before async storage gap in primary button handler (moved inside callback)
- Pre-flight null `flowId` check missing (added in `triggerRetrieve`)
- 5 MB size gate on `response.json` before clipboard/download
- `options.js` no `lastError` check on storage write (added)
- `privacy-policy.html` stale references (fully updated)

---

## Code

### `manifest.json`

```json
{
  "manifest_version": 3,
  "name": "Flow Retriever",
  "version": "1.1.0",
  "description": "One-click Salesforce Flow JSON extraction directly from the browser.",
  "icons": {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  },
  "permissions": [
    "cookies",
    "storage",
    "alarms"
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

// Reference-counted keepalive: alarm is created on first acquire and cleared
// only when all concurrent callers have released, preventing alarm collisions.
let _keepAliveCount = 0;
function withKeepAlive(asyncFn) {
    if (++_keepAliveCount === 1) chrome.alarms.create('sw-keepalive', { periodInMinutes: 0.1 });
    return asyncFn().finally(() => { if (--_keepAliveCount === 0) chrome.alarms.clear('sw-keepalive'); });
}

function isTrustedSender(sender) {
    if (!sender?.tab?.url) return false;
    try {
        const tabOrigin = new URL(sender.tab.url).origin;
        // sender.origin is the frame origin in MV3; fall back to tabOrigin if absent
        const frameOrigin = sender.origin || tabOrigin;
        return TRUSTED_ORIGINS.some(p => p.test(tabOrigin)) &&
               TRUSTED_ORIGINS.some(p => p.test(frameOrigin));
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
                    sendResponse({
                        success: true,
                        json: result.json,
                        flowApiName: result.flowApiName,
                        versionNumber: result.versionNumber
                    });
                    return;
                } catch (error) {
                    // Retry on 401 or network errors - cookie-derived apiDomains may not always be valid
                    if (error.cause === 401 || error instanceof TypeError) {
                        lastError = error.message;
                        continue;
                    }
                    sendResponse({ success: false, error: error.message });
                    return;
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
    return new Promise(resolve => chrome.cookies.getAll(details, resolve));
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

    const seen = new Set();
    const results = [];

    for (const domain of domainRoots) {
        const cookies = await getCookiesAll({ domain, name: 'sid' });
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

// Internal guard - validate flowId before building any SOQL query
async function fetchFlowIdentity(apiDomain, sessionId, flowId) {
    if (!FLOW_ID_PATTERN.test(flowId)) throw new Error('Invalid Flow ID passed to fetchFlowIdentity.');

    // Secondary sanitization before interpolation - defense in depth
    const safeId = flowId.replace(/[^a-zA-Z0-9]/g, '');
    const query = `SELECT Id, VersionNumber, Definition.DeveloperName FROM Flow WHERE Id = '${safeId}'`;
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
        if (err.name === 'AbortError') throw new Error('Request timed out resolving Flow identity.');
        throw err;
    } finally {
        clearTimeout(timeoutId);
    }

    if (!response.ok) {
        const err = new Error(`Salesforce API Error: ${response.status} ${response.statusText}`);
        err.cause = response.status;
        throw err;
    }

    const data = await response.json();
    if (!data.records || data.records.length === 0) {
        throw new Error('Flow identity not found.');
    }

    const record = data.records[0];
    return {
        developerName: record.Definition?.DeveloperName || null,
        versionNumber: record.VersionNumber || null
    };
}

// Internal guard - validate flowId before building any SOQL query
async function fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber) {
    if (!flowId || !FLOW_ID_PATTERN.test(flowId)) throw new Error('A valid Flow ID is required.');

    let ver = versionNumber != null ? Number(versionNumber) : null;
    let resolvedApiName = null;

    // Secondary sanitization before interpolation - defense in depth
    const safeId = flowId.replace(/[^a-zA-Z0-9]/g, '');
    const query = `SELECT Metadata FROM Flow WHERE Id = '${safeId}'`;

    try {
        const identity = await fetchFlowIdentity(apiDomain, sessionId, flowId);
        resolvedApiName = identity.developerName;
        ver = identity.versionNumber ?? ver;
    } catch (err) {
        // Re-throw 401 so caller's retry loop skips to the next session candidate
        if (err.cause === 401) throw err;
        // Log only err.message - never log sessionId or full error objects
        console.warn('[FlowRetriever] Could not resolve flow identity for filename:', err.message);
    }

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

    const jsonResponse = await response.json();

    if (!jsonResponse.records || jsonResponse.records.length === 0) {
        throw new Error(`Flow "${flowId}" (Version ${ver ?? 'Active'}) not found in this org.`);
    }

    const metadata = jsonResponse.records[0].Metadata;

    // Explicit null check - missing metadata means a permissions problem, not a missing flow
    if (metadata == null) {
        throw new Error(`Flow "${flowId}" returned no metadata. Check org permissions.`);
    }

    if (!resolvedApiName && metadata.label) {
        // Strip invalid filename chars, dots (prevents .. sequences), control characters,
        // and Unicode right-to-left override to prevent filename spoofing
        resolvedApiName = metadata.label.replace(/\s+/g, '_').replace(/[\\/:*?"<>|.\x00-\x1f‮​]/g, '');
    }

    return {
        json: JSON.stringify(metadata, null, 2),
        flowApiName: resolvedApiName || flowId,
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

    if (!document.getElementById('fxr-toast-styles')) {
        const style = document.createElement('style');
        style.id = 'fxr-toast-styles';
        style.textContent = `
            @keyframes fxr-slide-in { from { opacity:0; transform:translateX(20px); } to { opacity:1; transform:translateX(0); } }
            @keyframes fxr-fade-out { from { opacity:1; } to { opacity:0; transform:translateY(-6px); } }
        `;
        document.head.appendChild(style);
    }

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
    // Delay revoke to give browser time to initiate the download
    setTimeout(() => URL.revokeObjectURL(url), 5000);
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
let _dropdownListenerController = null;

// ==========================================
// SPA navigation watcher
// Patches pushState AND replaceState (Salesforce uses both) to detect navigation.
// Guard against patch accumulation on extension hot-reload via _fxrNavPatched flag.
// ==========================================
function watchForNavigation() {
    // Prevent stacking wrappers if content script context is reused
    if (window._fxrNavPatched) return;
    window._fxrNavPatched = true;

    let lastUrl = window.location.href;

    const handleNavigation = () => {
        const currentUrl = window.location.href;
        // Skip if URL has not meaningfully changed
        if (currentUrl === lastUrl) return;
        lastUrl = currentUrl;

        const existing = document.querySelector('#xml-retrieve-builder-btn');
        if (existing) {
            // Disconnect observer before removing the element to prevent memory/CPU leak
            if (_modalObserver) { _modalObserver.disconnect(); _modalObserver = null; }
            existing.remove();
        }

        if (currentUrl.includes('/builder_platform_interaction/flowBuilder')) {
            setTimeout(injectIntoFlowBuilder, 300);
        }
    };

    const originalPushState = history.pushState.bind(history);
    history.pushState = function (...args) {
        originalPushState(...args);
        handleNavigation();
    };

    // Salesforce also uses replaceState for in-place URL updates (e.g. version changes)
    const originalReplaceState = history.replaceState.bind(history);
    history.replaceState = function (...args) {
        originalReplaceState(...args);
        handleNavigation();
    };

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

    const MAX_JSON_CHARS = 5 * 1024 * 1024; // 5 MB guard

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
            if (response.json && response.json.length > MAX_JSON_CHARS) {
                showToast('Flow JSON exceeds 5 MB. Use Download instead.', 'error');
                return;
            }
            if (method === 'COPY') {
                copyToClipboard(response.json).then(() => {
                    showToast('Flow JSON copied to clipboard.', 'success');
                }).catch(() => {
                    showToast('Clipboard access denied. Use Download instead.', 'error');
                });
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
    if (document.querySelector('#xml-retrieve-builder-btn')) return;

    const wrapper = document.createElement('div');
    wrapper.id = 'xml-retrieve-builder-btn';

    const primaryBtn = document.createElement('button');
    primaryBtn.id = 'xml-retrieve-btn-primary';
    primaryBtn.textContent = 'JSON';
    primaryBtn.title = 'Execute default action (configurable in extension options)';
    primaryBtn.addEventListener('click', () => {
        // Resolve flowId inside the storage callback to avoid a race where the user
        // navigates between the click and the async callback firing
        chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
            const { flowId } = resolveFlowIdentityFromBuilder();
            triggerRetrieve(defaultAction, flowId);
        });
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

    // Memoize last modal state to avoid redundant DOM writes on every mutation.
    // Stored in module-level var so watchForNavigation can disconnect it on re-inject.
    let lastModalState = false;
    _modalObserver = new MutationObserver(() => {
        const modalOpen = !!document.querySelector('.modal-backdrop, .slds-backdrop_open');
        if (modalOpen !== lastModalState) {
            lastModalState = modalOpen;
            wrapper.style.display = modalOpen ? 'none' : 'flex';
        }
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

chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
    const safeDefault = ALLOWED_ACTIONS.has(defaultAction) ? defaultAction : 'COPY';
    if (safeDefault !== defaultAction) {
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
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'">
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
