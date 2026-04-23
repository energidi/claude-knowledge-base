# Design: Flow XML Retriever - Complete Fix

**Date:** 2026-04-16

---

## 1. Scope

Fix all critical, high, and medium issues identified in the code review. No new features.

---

## 2. New Files

| File | Purpose |
|---|---|
| `manifest.json` | MV3 manifest - permissions, content script URL routing, background service worker |
| `icons/icon16.png`, `icon48.png`, `icon128.png` | Placeholder icons required for extension load |

---

## 3. content.js - Complete Rewrite

### Entry Point Router
Detect URL on `window.location.href` at load time and call the correct inject function.

| URL pattern | Function |
|---|---|
| `/builder_platform_interaction/flowBuilder` | `injectIntoFlowBuilder()` |
| `/lightning/setup/Flows` | `injectIntoOldSetupPage()` |
| `/lightning/r/FlowRecord/` or `/lightning/r/Flow/` | `injectIntoNewLwcPage()` |

### `triggerRetrieve(method, flowApiName, versionNumber)`
- Sends `RETRIEVE_FLOW` message to background.js
- On response:
  - If `COPY`: calls `navigator.clipboard.writeText(xml)` (clipboard only available in content script, not service worker)
  - If `DOWNLOAD`: background already handled it
  - On error: `alert()` with error message

### `injectIntoFlowBuilder()` (Environment 1 - NEW)
- MutationObserver watches for `slds-button-group` container in Flow Builder header
- Injects SLDS split-button dropdown with two actions: "Copy XML" and "Download XML"
- Reads Flow API Name from page URL or breadcrumb
- Reads active version from page state or defaults to active version (no version number needed - query by DeveloperName + IsTemplate=false + Status='Active' or VersionNumber directly)
- Disconnects observer after injection

### `injectIntoOldSetupPage()` (Environment 2 - Fix)
- No functional changes to injection logic
- Move `xml-injected-old` class to the `actionCell` row, not the link, to avoid re-injection on re-renders

### `injectIntoNewLwcPage()` (Environment 3 - Fixes)
- Shadow DOM traversal: recursive `walkShadowRoots()` helper to find `lightning-formatted-text` for flow API name
- Fallback: parse flow ID from URL, pass to background.js to query by ID instead of name
- Observer debounced 200ms; injection guard keyed on `data-row-key` per row instead of global class
- Version number: require `data-label="Version Number"` cell; skip row with console warning if not found

---

## 4. background.js - Targeted Fixes

| Fix | Detail |
|---|---|
| API version constant | `const SF_API_VERSION = 'v66.0'` |
| SOQL injection | Validate `flowApiName` against `/^[a-zA-Z][a-zA-Z0-9_]*$/` before use |
| Fetch timeout | `AbortController` with 15s timeout |
| FileReader removal | `URL.createObjectURL(blob)` + `URL.revokeObjectURL` after download |
| COPY path | XML already in `sendResponse({ success: true, xml })` - content script handles clipboard write |

---

## 5. custom.css

No changes.

---

## 6. Security

- Input validation on `flowApiName` prevents SOQL injection from malicious page DOM
- All processing remains in-browser; no external servers
- Clipboard write happens in content script context where Clipboard API is available
