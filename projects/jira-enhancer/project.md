# Jira Enhancer - Chrome Extension

> Floating headers, quick copy, and smart search for Jira

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)]()
[![Chrome](https://img.shields.io/badge/chrome-MV3-green.svg)]()
[![License](https://img.shields.io/badge/license-MIT-gray.svg)]()

---

## Quick Start

### Prerequisites

- Chrome 88+ (Manifest V3 support)
- Access to a Jira Cloud (`*.atlassian.net`) or Server/Data Center instance

### Installation (Development)

1. Open `chrome://extensions`
2. Enable **Developer mode** (top right toggle)
3. Click **Load unpacked**
4. Select this project folder
5. Navigate to any Jira page — the extension activates automatically

### Reloading after code changes

1. Go to `chrome://extensions`
2. Click the circular reload (↺) arrow on the Jira Enhancer card
3. Hard-refresh the Jira tab (`Ctrl+F5`)

---

## Project Overview

A Chrome extension that improves daily Jira workflows through three core features:

1. **Floating Title Header** — Keeps ticket key and title visible in a thin bar at the top of the page while scrolling down a ticket
2. **Quick Copy Buttons** — Inline copy buttons next to the ticket title for copying the key and the title text
3. **Persistent Search Bar** — Always-visible centered search bar (below Jira's header) that searches issues via JQL with fallback strategies; shows 10 most-recently-updated issues when focused empty

---

## Architecture

### Extension Type
Chrome Manifest V3 (MV3)

### Script contexts

| Context | Files | Notes |
|---------|-------|-------|
| Content scripts | `lib/jira-selectors.js`, `lib/jql-builder.js`, `lib/dom-observer.js`, `floating-header.js`, `inline-copy.js`, `search-modal.js`, `content.js` | Run on `https://*.atlassian.net/*`. Plain scripts only — no ES module `import`/`export`. Globals shared via `window.X`. |
| Background service worker | `background.js` | ES module (`"type": "module"`). Handles keyboard shortcut forwarding. Search is **no longer done here** — moved to content script. |
| Options page | `options.html` + `options.js` | Settings UI popup |

### Key architectural decisions

- **Content scripts cannot use ES modules.** All `import`/`export` statements were removed from content script files. Instead, each file exports its class/object as `window.X = X` so subsequent scripts can reference it.
- **Search runs in the content script, not the background worker.** Fetching the Jira REST API from a background service worker hits CORS/auth issues even with `credentials: 'include'`. Fetching directly from the content script uses relative URLs (e.g. `/rest/api/3/search`) which are same-origin, so browser session cookies are included automatically with no CORS friction.
- **Ticket key is read from the URL, not the DOM.** `JiraSelectors.currentKey()` reads `/browse/PROJ-123` or `/issues/PROJ-123` from `window.location.pathname`. This avoids the ambiguity of breadcrumb DOM selectors which can return a parent project key instead of the current ticket key.

---

## File Reference

### `manifest.json`
- Manifest V3
- `host_permissions`: `https://*.atlassian.net/*` (required for cookie-based API access)
- `optional_host_permissions`: `https://*/*`, `http://*/*` (for self-hosted Jira, granted on demand from Options page)
- `commands`: `open-search` → `Ctrl+Shift+K` / `Command+Shift+K` — focuses the search bar
- Content scripts load order: `jira-selectors.js` → `jql-builder.js` → `dom-observer.js` → `floating-header.js` → `inline-copy.js` → `search-modal.js` → `content.js`

### `content.js`
Entry point. Calls `window.JiraSelectors.detect()`, then initialises `FloatingHeader`, `InlineCopyButtons`, and `SearchModal` based on feature flags from `chrome.storage.sync`.

### `lib/jira-selectors.js` → `window.JiraSelectors`
- `detect()` — sets `platform` to `'cloud'` or `'server'` based on hostname
- `ticketTitle` — comma-separated CSS selector list with multiple cloud fallbacks
- `ticketKey` — CSS selectors for breadcrumb key element (less reliable than URL)
- `currentKey()` — **preferred** — reads key from URL pathname via regex `/\/(?:browse|issues)\/([A-Z]+-\d+)/i`
- `apiBase` — `/rest/api/3` (cloud) or `/rest/api/2` (server)

### `lib/jql-builder.js` → `window.JQLBuilder`
Builds JQL queries with three strategies:
- **primary**: exact phrase `summary ~ "\"term\""`
- **fallback**: AND-chained individual terms `summary ~ "word1" AND summary ~ "word2"`
- **broad**: full-text `text ~ "term"`
- `isTicketKey(input)` — detects `PROJ-123` pattern
- `buildKeySearch(key)` — builds `key = "PROJ-123"` or `key ~ "PROJ*"` for partial
- `sanitize(input)` — strips JQL special characters
- `tokenize(input)` — splits into meaningful words, filters stop words

### `lib/dom-observer.js` → `window.DOMObserver`
`JiraDOMObserver` — wraps `MutationObserver` and `popstate`/`pushstate` intercept to notify registered handlers of navigation and DOM changes in Jira's SPA.

### `floating-header.js` → `window.FloatingHeader`
- Injects a `div.je-floating-header` into `document.body`
- Uses `IntersectionObserver` on the ticket title element to show/hide the floating bar
- Reads ticket key from `JiraSelectors.currentKey()` (URL-based)
- Copy button in the header copies the ticket key to clipboard

### `inline-copy.js` → `window.InlineCopyButtons`
- Injects small clipboard-icon buttons next to the ticket title on ticket detail pages
- One button copies the ticket key, one copies the title text
- Uses `data-type="key"` / `data-type="title"` attributes for deduplication
- Re-injects on SPA navigation via `DOMObserver`

### `search-modal.js` → `window.SearchModal`
- Injects `#je-search-bar` — a **persistent always-visible** fixed search bar centered horizontally below Jira's header (`top: 110px`)
- On focus (empty input): loads 10 most recently updated issues (`ORDER BY updated DESC`)
- On input (≥2 chars): debounced 300ms search via Jira REST API
- Fetch is done **directly from the content script** using relative URL `/rest/api/${apiVersion}/search` — same-origin, uses session cookies
- JQL fallback: if exact-phrase match returns 0 results, retries with AND-chained terms
- Keyboard: `↑`/`↓` navigate, `Enter` opens in same tab, `Ctrl+Enter` opens in new tab, `Escape` closes dropdown
- `Ctrl+Shift+K` (or via `chrome.runtime.onMessage` from background) focuses the bar

### `background.js`
- ES module. Imports `SimpleCache` and `JQLBuilder` (kept for potential future use).
- **Primary current role**: forwards the `open-search` keyboard shortcut command to the active tab's content script via `chrome.tabs.sendMessage`.
- Also handles `search` and `getAuthStatus` messages (legacy — search now done in content script directly).

### `options.js` + `options.html`
Settings page with fields:
- `serverUrl` — optional, for self-hosted Jira Server/DC (validated with `new URL()`)
- `apiToken` — Personal Access Token for Server/DC Bearer auth
- Feature toggles: `enableFloatingHeader`, `enableCopyButtons`, `enableSearch`

---

## CSS Classes Reference (`styles.css`)

### Floating Header
| Class | Purpose |
|-------|---------|
| `.je-floating-header` | Fixed bar at `top: 0`, slides in/out with CSS transform |
| `.je-floating-header.je-hidden` | `translateY(-100%)` — slides off screen |
| `.je-ticket-key` | Blue bold key label |
| `.je-ticket-title` | Truncated title with ellipsis |

### Copy Buttons
| Class | Purpose |
|-------|---------|
| `.je-copy-btn` | Copy button in floating header |
| `.je-inline-copy` | Copy button next to title (opacity 0, reveals on hover) |
| `.je-copy-success` | Green flash on success |
| `.je-copy-error` | Red flash on failure |

### Search Bar
| Class | Purpose |
|-------|---------|
| `#je-search-bar` | Fixed container, `top: 110px`, `left: 50%`, `width: 600px` |
| `.je-searchbar-input-wrapper` | White rounded input row with shadow |
| `.je-searchbar-dropdown` | `position: absolute` dropdown below input |
| `.je-results-list` | Scrollable results, max 320px height |
| `.je-result-item` | Single result row with left-border highlight |
| `.je-status-{new,indeterminate,done,undefined}` | Status badge colors |
| `.je-searchbar-footer` | `↑↓ Navigate | Enter Open | Ctrl+Enter New tab` hint bar |

### Utility
| Class | Purpose |
|-------|---------|
| `.je-hidden` | `display: none !important` |

---

## Platform Compatibility

### Jira Cloud (`*.atlassian.net`)
- API version: `v3`
- Auth: session cookies (automatic — content script is same-origin)
- URL pattern: `/browse/PROJ-123` or `/issues/PROJ-123`
- Content scripts match via `"matches": ["https://*.atlassian.net/*"]`

### Jira Server / Data Center
- API version: `v2`
- Auth: Bearer token (configured in Options → API Token)
- Requires granting optional host permission for the custom domain
- Content scripts do **not** auto-run on Server — user must grant permission

---

## Known Issues / Pending

1. **Search bar vertical position** — currently hardcoded `top: 110px`. Jira Cloud header height varies slightly across layouts. If the bar overlaps Jira's header, increase this value in `styles.css`.
2. **Jira Server search** — content script doesn't run on Server domains by default (only `*.atlassian.net` is in `matches`). For Server support, the user must grant the optional host permission via Options.
3. **SPA navigation** — `DOMObserver` handles most navigation, but deeply nested React re-renders may occasionally require a manual page refresh.

---

## Debugging

Open **DevTools → Console** on a Jira page and check for:

```
[Jira Enhancer] Initialized
```

If missing, the content script isn't running — reload the extension at `chrome://extensions`.

To verify the search bar is injected:
```js
document.getElementById('je-search-bar')
```

To verify selectors work:
```js
window.JiraSelectors.detect()
window.JiraSelectors.currentKey()
document.querySelector(window.JiraSelectors.ticketTitle)
```

---

## Changelog

### Session 2 (post-initial-build fixes)

**Critical bug fixes:**
- Removed all `import`/`export` ES module syntax from content scripts (Chrome content scripts don't support ES modules)
- Added missing files to `manifest.json` content_scripts list: `floating-header.js`, `inline-copy.js`, `search-modal.js`
- Added `lib/jql-builder.js` to content scripts list (needed after search moved to content script)
- Converted all lib files to `window.X` globals instead of ES module exports

**Selector fixes:**
- `JiraSelectors.currentKey()` — new URL-based method replaces unreliable DOM breadcrumb selector
- Added multiple CSS fallback selectors for `ticketTitle` and `ticketKey`
- Fixed floating header and inline copy to use `currentKey()` from URL

**Search bar redesign:**
- Replaced popup modal with persistent always-visible fixed bar
- Positioned centered at `top: 110px` (below Jira's ~56px header)
- Width: 600px
- Moved search fetch from background service worker to content script (same-origin relative URLs — fixes auth/CORS issues)
- On empty focus: shows 10 most recently updated issues
- Error messages now normalize `API_ERROR:403` style codes correctly

**Options:**
- Added URL validation for `serverUrl` field before saving

**Background:**
- Added `chrome.commands.onCommand` to forward `Ctrl+Shift+K` shortcut to content script
- Added `X-Atlassian-Token: no-check` header (CSRF bypass for REST API)
