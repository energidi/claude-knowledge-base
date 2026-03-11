# Jira Enhancer - Chrome Extension

> Floating headers, quick copy, and smart search for Jira

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)]()
[![Chrome](https://img.shields.io/badge/chrome-MV3-green.svg)]()
[![License](https://img.shields.io/badge/license-MIT-gray.svg)]()

---

## Quick Start

### Prerequisites

- Node.js 18+ (for development tooling)
- Chrome 88+ (Manifest V3 support)
- Access to a Jira Cloud or Server instance

### Installation (Development)

```bash
# Clone the repository
git clone https://github.com/yourorg/jira-enhancer.git
cd jira-enhancer

# Install dev dependencies (optional - for linting/testing)
npm install

# Load in Chrome
1. Open chrome://extensions
2. Enable "Developer mode" (top right)
3. Click "Load unpacked"
4. Select the project folder
```

### Installation (Production)

1. Download from Chrome Web Store (link TBD)
2. Click "Add to Chrome"
3. Navigate to any Jira page

---

## Development Commands

```bash
# Lint code
npm run lint

# Fix lint issues
npm run lint:fix

# Run unit tests
npm test

# Run tests with coverage
npm run test:coverage

# Build for production (zip for Chrome Web Store)
npm run build

# Watch mode (auto-reload extension on changes)
npm run dev
```

---

## Project Overview

A Chrome extension that improves daily Jira workflows through three core features:

1. **Floating Title Header** - Keeps ticket ID and title visible while scrolling
2. **Quick Copy Actions** - One-click copy for ticket ID, URL, and title
3. **Smart Search Modal** - Keyboard-triggered search with intelligent JQL that actually finds what you type

This document covers architecture, implementation details, error handling, and platform compatibility for both Jira Cloud and Jira Server/Data Center.

---

## 1. Project Structure

```
jira-enhancer/
├── manifest.json              # Extension config and permissions
├── background.js              # Service worker for API calls
├── content.js                 # DOM manipulation and UI injection
├── options.html               # Settings page
├── options.js                 # Settings logic
├── styles.css                 # Injected styles
├── icons/
│   ├── icon16.png
│   ├── icon48.png
│   └── icon128.png
└── lib/
    ├── jira-selectors.js      # Centralized DOM selectors
    ├── jql-builder.js         # Smart query construction
    ├── dom-observer.js        # MutationObserver wrapper
    └── cache.js               # Simple TTL cache
```

---

## 2. Manifest Configuration

```json
{
  "manifest_version": 3,
  "name": "Jira Enhancer",
  "version": "1.0.0",
  "description": "Floating headers, quick copy, and smart search for Jira",
  
  "permissions": [
    "activeTab",
    "clipboardWrite",
    "storage"
  ],
  
  "host_permissions": [
    "https://*.atlassian.net/*"
  ],
  
  "optional_host_permissions": [
    "https://*/*",
    "http://*/*"
  ],
  
  "background": {
    "service_worker": "background.js",
    "type": "module"
  },
  
  "content_scripts": [
    {
      "matches": ["https://*.atlassian.net/*"],
      "js": ["lib/jira-selectors.js", "lib/dom-observer.js", "content.js"],
      "css": ["styles.css"],
      "run_at": "document_idle"
    }
  ],
  
  "options_ui": {
    "page": "options.html",
    "open_in_tab": false
  },
  
  "commands": {
    "open-search": {
      "suggested_key": {
        "default": "Ctrl+Shift+K",
        "mac": "Command+Shift+K"
      },
      "description": "Open Jira search modal"
    }
  },
  
  "icons": {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png"
  }
}
```

### Key Decisions

| Choice | Reasoning |
|--------|-----------|
| `Ctrl+Shift+K` over `Ctrl+K` | Avoids conflicts with browser, Jira native, Slack, Notion |
| `optional_host_permissions` | Allows Server/Data Center users to add their domain |
| `run_at: document_idle` | Ensures DOM is ready before injection |
| `type: module` for service worker | Enables ES6 imports in background script |

---

## 3. Platform Detection

Jira Cloud and Server have different DOM structures and API endpoints. Detection must happen early.

### lib/jira-selectors.js

```javascript
const JiraSelectors = {
  platform: null,
  
  detect() {
    // Cloud uses atlassian.net domain
    if (window.location.hostname.includes('atlassian.net')) {
      this.platform = 'cloud';
    } else {
      this.platform = 'server';
    }
    return this.platform;
  },
  
  // Selectors differ by platform
  get ticketTitle() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-base.foundation.summary.heading"]'
      : '#summary-val, .issue-header-content h1';
  },
  
  get ticketKey() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-base.foundation.breadcrumbs.current-issue.item"] span'
      : '#key-val, .issue-link';
  },
  
  get mainContent() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-details.issue-layout.container-left"]'
      : '#details-module, .issue-body-content';
  },
  
  // API base URL
  get apiBase() {
    if (this.platform === 'cloud') {
      const match = window.location.pathname.match(/\/browse\/([A-Z]+)-/);
      return `/rest/api/3`;
    }
    return `/rest/api/2`;
  }
};

export default JiraSelectors;
```

---

## 4. DOM Observer System

Jira is a React SPA. The DOM changes constantly. A robust observer is critical.

### lib/dom-observer.js

```javascript
class JiraDOMObserver {
  constructor() {
    this.observer = null;
    this.callbacks = new Map();
    this.lastUrl = window.location.href;
  }
  
  init() {
    // Watch for DOM changes
    this.observer = new MutationObserver((mutations) => {
      this.handleMutations(mutations);
    });
    
    this.observer.observe(document.body, {
      childList: true,
      subtree: true
    });
    
    // Watch for SPA navigation (URL changes without page reload)
    this.startUrlWatcher();
  }
  
  startUrlWatcher() {
    // Jira uses history API for navigation
    const originalPushState = history.pushState;
    const originalReplaceState = history.replaceState;
    
    history.pushState = (...args) => {
      originalPushState.apply(history, args);
      this.handleNavigation();
    };
    
    history.replaceState = (...args) => {
      originalReplaceState.apply(history, args);
      this.handleNavigation();
    };
    
    window.addEventListener('popstate', () => this.handleNavigation());
  }
  
  handleNavigation() {
    if (window.location.href !== this.lastUrl) {
      this.lastUrl = window.location.href;
      this.callbacks.forEach((callback, name) => {
        if (callback.onNavigate) {
          callback.onNavigate();
        }
      });
    }
  }
  
  handleMutations(mutations) {
    // Debounce to avoid excessive re-runs
    clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.callbacks.forEach((callback) => {
        if (callback.onDOMChange) {
          callback.onDOMChange(mutations);
        }
      });
    }, 100);
  }
  
  register(name, callbacks) {
    this.callbacks.set(name, callbacks);
  }
  
  unregister(name) {
    this.callbacks.delete(name);
  }
  
  destroy() {
    if (this.observer) {
      this.observer.disconnect();
    }
  }
}

export default new JiraDOMObserver();
```

---

## 5. Feature: Floating Title Header

### Behavior

- Appears when user scrolls past the native title
- Shows: Ticket Key (e.g., PROJ-1234) + Title
- Includes copy buttons for both
- Auto-hides when scrolling back up
- Re-injects after SPA navigation

### Implementation in content.js

```javascript
import JiraSelectors from './lib/jira-selectors.js';
import DOMObserver from './lib/dom-observer.js';

class FloatingHeader {
  constructor() {
    this.header = null;
    this.titleObserver = null;
    this.isVisible = false;
  }
  
  init() {
    JiraSelectors.detect();
    this.createHeader();
    this.setupIntersectionObserver();
    
    DOMObserver.register('floatingHeader', {
      onNavigate: () => this.reinject(),
      onDOMChange: () => this.checkTitleExists()
    });
  }
  
  createHeader() {
    // Remove existing if present
    const existing = document.getElementById('jira-enhancer-header');
    if (existing) existing.remove();
    
    this.header = document.createElement('div');
    this.header.id = 'jira-enhancer-header';
    this.header.className = 'je-floating-header je-hidden';
    this.header.innerHTML = `
      <div class="je-header-content">
        <span class="je-ticket-key"></span>
        <button class="je-copy-btn" data-copy="key" title="Copy ticket key">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
          </svg>
        </button>
        <span class="je-divider">|</span>
        <span class="je-ticket-title"></span>
        <button class="je-copy-btn" data-copy="title" title="Copy title">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
          </svg>
        </button>
        <button class="je-copy-btn" data-copy="url" title="Copy URL">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
            <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path>
          </svg>
        </button>
      </div>
    `;
    
    document.body.appendChild(this.header);
    this.attachCopyListeners();
  }
  
  setupIntersectionObserver() {
    // Wait for title element to exist
    this.waitForElement(JiraSelectors.ticketTitle, (titleElement) => {
      this.updateHeaderContent();
      
      this.titleObserver = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) {
              this.hide();
            } else if (entry.boundingClientRect.top < 0) {
              this.show();
            }
          });
        },
        { threshold: 0, rootMargin: '-60px 0px 0px 0px' }
      );
      
      this.titleObserver.observe(titleElement);
    });
  }
  
  waitForElement(selector, callback, maxAttempts = 50) {
    let attempts = 0;
    const check = () => {
      const element = document.querySelector(selector);
      if (element) {
        callback(element);
      } else if (attempts < maxAttempts) {
        attempts++;
        setTimeout(check, 100);
      }
    };
    check();
  }
  
  updateHeaderContent() {
    const keyElement = document.querySelector(JiraSelectors.ticketKey);
    const titleElement = document.querySelector(JiraSelectors.ticketTitle);
    
    if (keyElement && titleElement) {
      this.header.querySelector('.je-ticket-key').textContent = keyElement.textContent.trim();
      this.header.querySelector('.je-ticket-title').textContent = titleElement.textContent.trim();
    }
  }
  
  show() {
    if (!this.isVisible) {
      this.header.classList.remove('je-hidden');
      this.isVisible = true;
    }
  }
  
  hide() {
    if (this.isVisible) {
      this.header.classList.add('je-hidden');
      this.isVisible = false;
    }
  }
  
  reinject() {
    // Disconnect old observer
    if (this.titleObserver) {
      this.titleObserver.disconnect();
    }
    this.hide();
    
    // Re-setup after navigation
    setTimeout(() => {
      this.setupIntersectionObserver();
    }, 500);
  }
  
  checkTitleExists() {
    const titleElement = document.querySelector(JiraSelectors.ticketTitle);
    if (titleElement && !this.titleObserver) {
      this.setupIntersectionObserver();
    }
  }
  
  attachCopyListeners() {
    this.header.querySelectorAll('.je-copy-btn').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        const copyType = btn.dataset.copy;
        this.handleCopy(copyType, btn);
      });
    });
  }
  
  async handleCopy(type, button) {
    const keyElement = document.querySelector(JiraSelectors.ticketKey);
    const titleElement = document.querySelector(JiraSelectors.ticketTitle);
    
    let text = '';
    switch (type) {
      case 'key':
        text = keyElement?.textContent.trim() || '';
        break;
      case 'title':
        text = titleElement?.textContent.trim() || '';
        break;
      case 'url':
        text = window.location.href.split('?')[0];
        break;
    }
    
    if (text) {
      try {
        await navigator.clipboard.writeText(text);
        this.showCopyFeedback(button, true);
      } catch (err) {
        this.showCopyFeedback(button, false);
      }
    }
  }
  
  showCopyFeedback(button, success) {
    button.classList.add(success ? 'je-copy-success' : 'je-copy-error');
    setTimeout(() => {
      button.classList.remove('je-copy-success', 'je-copy-error');
    }, 1000);
  }
}

export default FloatingHeader;
```

---

## 6. Feature: Inline Copy Icons

Adds copy buttons next to the ticket key and title in their native positions.

```javascript
class InlineCopyButtons {
  constructor() {
    this.injected = false;
  }
  
  init() {
    DOMObserver.register('inlineCopy', {
      onNavigate: () => this.reinject(),
      onDOMChange: () => this.injectIfNeeded()
    });
    
    this.injectIfNeeded();
  }
  
  injectIfNeeded() {
    if (this.injected) return;
    
    const keyElement = document.querySelector(JiraSelectors.ticketKey);
    const titleElement = document.querySelector(JiraSelectors.ticketTitle);
    
    if (keyElement && !keyElement.querySelector('.je-inline-copy')) {
      this.addCopyButton(keyElement, 'key');
    }
    
    if (titleElement && !titleElement.parentElement.querySelector('.je-inline-copy')) {
      this.addCopyButton(titleElement.parentElement, 'title');
    }
    
    if (keyElement && titleElement) {
      this.injected = true;
    }
  }
  
  addCopyButton(container, type) {
    const btn = document.createElement('button');
    btn.className = 'je-inline-copy';
    btn.title = `Copy ${type}`;
    btn.innerHTML = `
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
      </svg>
    `;
    
    btn.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();
      
      let text = '';
      if (type === 'key') {
        text = document.querySelector(JiraSelectors.ticketKey)?.textContent.trim();
      } else {
        text = document.querySelector(JiraSelectors.ticketTitle)?.textContent.trim();
      }
      
      if (text) {
        try {
          await navigator.clipboard.writeText(text);
          btn.classList.add('je-copy-success');
        } catch {
          btn.classList.add('je-copy-error');
        }
        setTimeout(() => btn.classList.remove('je-copy-success', 'je-copy-error'), 1000);
      }
    });
    
    container.appendChild(btn);
  }
  
  reinject() {
    this.injected = false;
    document.querySelectorAll('.je-inline-copy').forEach(el => el.remove());
    setTimeout(() => this.injectIfNeeded(), 500);
  }
}

export default InlineCopyButtons;
```

---

## 7. Feature: Smart Search Modal

### JQL Builder

The native Jira search fails because it tokenizes poorly. Our JQL builder fixes this.

### lib/jql-builder.js

```javascript
class JQLBuilder {
  constructor() {
    // Characters that break JQL
    this.specialChars = /[+\-&|!(){}[\]^"~*?:\\]/g;
  }
  
  /**
   * Build a smart JQL query with fallback strategies
   * @param {string} input - User's search text
   * @param {string} projectKey - Optional project filter
   * @returns {object} - { primary: string, fallback: string }
   */
  build(input, projectKey = null) {
    const sanitized = this.sanitize(input);
    const terms = this.tokenize(sanitized);
    
    let projectFilter = projectKey ? `project = "${projectKey}" AND ` : '';
    
    // Strategy 1: Exact phrase match (works best for copy-pasted titles)
    const primary = `${projectFilter}summary ~ "\\"${sanitized}\\""`;
    
    // Strategy 2: AND-chained terms (fallback if exact match returns nothing)
    const termClauses = terms.map(term => `summary ~ "${term}"`).join(' AND ');
    const fallback = `${projectFilter}${termClauses}`;
    
    // Strategy 3: Broad text search (last resort)
    const broad = `${projectFilter}text ~ "${sanitized}"`;
    
    return {
      primary,
      fallback,
      broad,
      orderBy: ' ORDER BY updated DESC'
    };
  }
  
  sanitize(input) {
    return input
      .trim()
      .replace(this.specialChars, ' ')
      .replace(/\s+/g, ' ');
  }
  
  tokenize(input) {
    // Split into words, filter out short/common words
    const stopWords = ['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'for', 'on', 'with'];
    return input
      .toLowerCase()
      .split(' ')
      .filter(word => word.length > 2 && !stopWords.includes(word));
  }
  
  /**
   * Build query for ticket key search (PROJ-1234)
   */
  buildKeySearch(key) {
    // Direct key match
    if (/^[A-Z]+-\d+$/i.test(key)) {
      return `key = "${key.toUpperCase()}"`;
    }
    // Partial key search
    return `key ~ "${key.toUpperCase()}*"`;
  }
  
  /**
   * Detect if input looks like a ticket key
   */
  isTicketKey(input) {
    return /^[A-Z]{2,10}-?\d*$/i.test(input.trim());
  }
}

export default new JQLBuilder();
```

### Cache Layer

### lib/cache.js

```javascript
class SimpleCache {
  constructor(ttlMs = 60000) {
    this.cache = new Map();
    this.ttl = ttlMs;
  }
  
  get(key) {
    const entry = this.cache.get(key);
    if (!entry) return null;
    
    if (Date.now() > entry.expires) {
      this.cache.delete(key);
      return null;
    }
    
    return entry.value;
  }
  
  set(key, value) {
    this.cache.set(key, {
      value,
      expires: Date.now() + this.ttl
    });
  }
  
  clear() {
    this.cache.clear();
  }
}

export default SimpleCache;
```

### Background Service Worker

### background.js

```javascript
import SimpleCache from './lib/cache.js';
import JQLBuilder from './lib/jql-builder.js';

const cache = new SimpleCache(60000); // 60 second TTL

// Listen for search requests from content script
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'search') {
    handleSearch(request, sender.tab)
      .then(sendResponse)
      .catch(err => sendResponse({ error: err.message }));
    return true; // Keep channel open for async response
  }
  
  if (request.action === 'getAuthStatus') {
    checkAuthStatus(request.domain)
      .then(sendResponse)
      .catch(err => sendResponse({ error: err.message }));
    return true;
  }
});

async function handleSearch({ query, domain, apiVersion, projectKey }) {
  // Check cache first
  const cacheKey = `${domain}:${query}:${projectKey || 'all'}`;
  const cached = cache.get(cacheKey);
  if (cached) {
    return { results: cached, fromCache: true };
  }
  
  // Build smart JQL
  const jql = JQLBuilder.isTicketKey(query)
    ? JQLBuilder.buildKeySearch(query)
    : JQLBuilder.build(query, projectKey);
  
  // Try primary query first
  let results = await executeSearch(domain, apiVersion, jql.primary + jql.orderBy);
  
  // Fallback if no results
  if (results.length === 0 && !JQLBuilder.isTicketKey(query)) {
    results = await executeSearch(domain, apiVersion, jql.fallback + jql.orderBy);
  }
  
  // Broad search as last resort
  if (results.length === 0 && !JQLBuilder.isTicketKey(query)) {
    results = await executeSearch(domain, apiVersion, jql.broad + jql.orderBy);
  }
  
  // Cache results
  cache.set(cacheKey, results);
  
  return { results, fromCache: false };
}

async function executeSearch(domain, apiVersion, jql) {
  const baseUrl = `https://${domain}/rest/api/${apiVersion}`;
  const url = `${baseUrl}/search?jql=${encodeURIComponent(jql)}&maxResults=10&fields=key,summary,status,assignee,updated`;
  
  try {
    const response = await fetch(url, {
      method: 'GET',
      credentials: 'include', // Send cookies for auth
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
    });
    
    if (response.status === 401) {
      throw new Error('AUTH_REQUIRED');
    }
    
    if (response.status === 429) {
      throw new Error('RATE_LIMITED');
    }
    
    if (!response.ok) {
      throw new Error(`API_ERROR:${response.status}`);
    }
    
    const data = await response.json();
    
    return data.issues.map(issue => ({
      key: issue.key,
      summary: issue.fields.summary,
      status: issue.fields.status?.name || 'Unknown',
      statusCategory: issue.fields.status?.statusCategory?.key || 'undefined',
      assignee: issue.fields.assignee?.displayName || 'Unassigned',
      updated: issue.fields.updated,
      url: `https://${domain}/browse/${issue.key}`
    }));
    
  } catch (err) {
    if (err.message.startsWith('AUTH') || err.message.startsWith('RATE') || err.message.startsWith('API')) {
      throw err;
    }
    throw new Error('NETWORK_ERROR');
  }
}

async function checkAuthStatus(domain) {
  try {
    const response = await fetch(`https://${domain}/rest/api/3/myself`, {
      credentials: 'include'
    });
    return { authenticated: response.ok };
  } catch {
    return { authenticated: false };
  }
}
```

### Search Modal UI

### content.js (search modal portion)

```javascript
class SearchModal {
  constructor() {
    this.modal = null;
    this.input = null;
    this.results = null;
    this.selectedIndex = -1;
    this.searchResults = [];
    this.debounceTimer = null;
    this.isOpen = false;
  }
  
  init() {
    this.createModal();
    this.attachListeners();
    
    // Listen for keyboard shortcut from background
    chrome.runtime.onMessage.addListener((request) => {
      if (request.action === 'openSearch') {
        this.open();
      }
    });
    
    // Also listen for direct keyboard events (backup)
    document.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'K') {
        e.preventDefault();
        this.toggle();
      }
      
      if (e.key === 'Escape' && this.isOpen) {
        this.close();
      }
    });
  }
  
  createModal() {
    this.modal = document.createElement('div');
    this.modal.id = 'je-search-modal';
    this.modal.className = 'je-modal je-hidden';
    this.modal.innerHTML = `
      <div class="je-modal-backdrop"></div>
      <div class="je-modal-container">
        <div class="je-modal-header">
          <div class="je-search-input-wrapper">
            <svg class="je-search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"></circle>
              <path d="m21 21-4.35-4.35"></path>
            </svg>
            <input type="text" class="je-search-input" placeholder="Search Jira tickets..." autocomplete="off" />
            <span class="je-search-hint">ESC to close</span>
          </div>
        </div>
        <div class="je-modal-body">
          <div class="je-results-container">
            <div class="je-results-list"></div>
            <div class="je-results-empty je-hidden">No results found</div>
            <div class="je-results-loading je-hidden">
              <div class="je-spinner"></div>
              Searching...
            </div>
            <div class="je-results-error je-hidden"></div>
          </div>
        </div>
        <div class="je-modal-footer">
          <span class="je-footer-hint">
            <kbd>↑</kbd><kbd>↓</kbd> Navigate
            <kbd>Enter</kbd> Open
            <kbd>Ctrl+Enter</kbd> Open in new tab
          </span>
        </div>
      </div>
    `;
    
    document.body.appendChild(this.modal);
    
    this.input = this.modal.querySelector('.je-search-input');
    this.results = this.modal.querySelector('.je-results-list');
    this.emptyState = this.modal.querySelector('.je-results-empty');
    this.loadingState = this.modal.querySelector('.je-results-loading');
    this.errorState = this.modal.querySelector('.je-results-error');
  }
  
  attachListeners() {
    // Close on backdrop click
    this.modal.querySelector('.je-modal-backdrop').addEventListener('click', () => {
      this.close();
    });
    
    // Input handling
    this.input.addEventListener('input', () => {
      this.handleInput();
    });
    
    // Keyboard navigation
    this.input.addEventListener('keydown', (e) => {
      this.handleKeydown(e);
    });
  }
  
  handleInput() {
    const query = this.input.value.trim();
    
    clearTimeout(this.debounceTimer);
    
    if (query.length < 2) {
      this.clearResults();
      return;
    }
    
    this.showLoading();
    
    this.debounceTimer = setTimeout(() => {
      this.search(query);
    }, 300);
  }
  
  async search(query) {
    const domain = window.location.hostname;
    const apiVersion = domain.includes('atlassian.net') ? '3' : '2';
    
    try {
      const response = await chrome.runtime.sendMessage({
        action: 'search',
        query,
        domain,
        apiVersion
      });
      
      if (response.error) {
        this.showError(response.error);
        return;
      }
      
      this.searchResults = response.results;
      this.renderResults();
      
    } catch (err) {
      this.showError('NETWORK_ERROR');
    }
  }
  
  renderResults() {
    this.hideLoading();
    
    if (this.searchResults.length === 0) {
      this.emptyState.classList.remove('je-hidden');
      this.results.innerHTML = '';
      return;
    }
    
    this.emptyState.classList.add('je-hidden');
    this.selectedIndex = 0;
    
    this.results.innerHTML = this.searchResults.map((result, index) => `
      <div class="je-result-item ${index === 0 ? 'je-selected' : ''}" data-index="${index}">
        <div class="je-result-key">${this.escapeHtml(result.key)}</div>
        <div class="je-result-summary">${this.escapeHtml(result.summary)}</div>
        <div class="je-result-meta">
          <span class="je-status je-status-${result.statusCategory}">${this.escapeHtml(result.status)}</span>
          <span class="je-assignee">${this.escapeHtml(result.assignee)}</span>
        </div>
      </div>
    `).join('');
    
    // Click handlers for results
    this.results.querySelectorAll('.je-result-item').forEach((item) => {
      item.addEventListener('click', (e) => {
        const index = parseInt(item.dataset.index);
        this.openResult(index, e.ctrlKey || e.metaKey);
      });
      
      item.addEventListener('mouseenter', () => {
        this.selectResult(parseInt(item.dataset.index));
      });
    });
  }
  
  handleKeydown(e) {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        this.selectResult(this.selectedIndex + 1);
        break;
        
      case 'ArrowUp':
        e.preventDefault();
        this.selectResult(this.selectedIndex - 1);
        break;
        
      case 'Enter':
        e.preventDefault();
        if (this.selectedIndex >= 0) {
          this.openResult(this.selectedIndex, e.ctrlKey || e.metaKey);
        }
        break;
    }
  }
  
  selectResult(index) {
    if (index < 0) index = this.searchResults.length - 1;
    if (index >= this.searchResults.length) index = 0;
    
    this.selectedIndex = index;
    
    this.results.querySelectorAll('.je-result-item').forEach((item, i) => {
      item.classList.toggle('je-selected', i === index);
    });
    
    // Scroll into view
    const selected = this.results.querySelector('.je-selected');
    if (selected) {
      selected.scrollIntoView({ block: 'nearest' });
    }
  }
  
  openResult(index, newTab = false) {
    const result = this.searchResults[index];
    if (!result) return;
    
    if (newTab) {
      window.open(result.url, '_blank');
    } else {
      window.location.href = result.url;
    }
    
    this.close();
  }
  
  showLoading() {
    this.loadingState.classList.remove('je-hidden');
    this.emptyState.classList.add('je-hidden');
    this.errorState.classList.add('je-hidden');
  }
  
  hideLoading() {
    this.loadingState.classList.add('je-hidden');
  }
  
  showError(errorCode) {
    this.hideLoading();
    this.emptyState.classList.add('je-hidden');
    this.errorState.classList.remove('je-hidden');
    
    const messages = {
      'AUTH_REQUIRED': 'Please log in to Jira to search',
      'RATE_LIMITED': 'Too many requests - please wait a moment',
      'NETWORK_ERROR': 'Unable to connect to Jira',
      'API_ERROR': 'Jira returned an error'
    };
    
    this.errorState.textContent = messages[errorCode] || 'An error occurred';
  }
  
  clearResults() {
    this.results.innerHTML = '';
    this.emptyState.classList.add('je-hidden');
    this.errorState.classList.add('je-hidden');
    this.searchResults = [];
    this.selectedIndex = -1;
  }
  
  open() {
    this.modal.classList.remove('je-hidden');
    this.input.focus();
    this.input.select();
    this.isOpen = true;
    document.body.style.overflow = 'hidden';
  }
  
  close() {
    this.modal.classList.add('je-hidden');
    this.input.value = '';
    this.clearResults();
    this.isOpen = false;
    document.body.style.overflow = '';
  }
  
  toggle() {
    if (this.isOpen) {
      this.close();
    } else {
      this.open();
    }
  }
  
  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
}

export default SearchModal;
```

---

## 8. Styles

### styles.css

```css
/* ===== Floating Header ===== */
.je-floating-header {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  height: 44px;
  background: #ffffff;
  border-bottom: 1px solid #dfe1e6;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.08);
  z-index: 999999;
  display: flex;
  align-items: center;
  padding: 0 16px;
  transform: translateY(0);
  transition: transform 0.2s ease, opacity 0.2s ease;
}

.je-floating-header.je-hidden {
  transform: translateY(-100%);
  opacity: 0;
  pointer-events: none;
}

.je-header-content {
  display: flex;
  align-items: center;
  gap: 8px;
  max-width: 100%;
  overflow: hidden;
}

.je-ticket-key {
  font-weight: 600;
  color: #0052cc;
  white-space: nowrap;
  font-size: 14px;
}

.je-ticket-title {
  color: #172b4d;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  font-size: 14px;
  max-width: 600px;
}

.je-divider {
  color: #dfe1e6;
  margin: 0 4px;
}

/* ===== Copy Buttons ===== */
.je-copy-btn,
.je-inline-copy {
  background: none;
  border: none;
  cursor: pointer;
  padding: 4px;
  border-radius: 4px;
  color: #6b778c;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.15s ease, color 0.15s ease;
}

.je-copy-btn:hover,
.je-inline-copy:hover {
  background: #ebecf0;
  color: #172b4d;
}

.je-copy-btn.je-copy-success,
.je-inline-copy.je-copy-success {
  color: #00875a;
  background: #e3fcef;
}

.je-copy-btn.je-copy-error,
.je-inline-copy.je-copy-error {
  color: #de350b;
  background: #ffebe6;
}

.je-inline-copy {
  margin-left: 8px;
  opacity: 0;
  transition: opacity 0.15s ease;
}

*:hover > .je-inline-copy,
.je-inline-copy:focus {
  opacity: 1;
}

/* ===== Search Modal ===== */
.je-modal {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 9999999;
  display: flex;
  align-items: flex-start;
  justify-content: center;
  padding-top: 15vh;
}

.je-modal.je-hidden {
  display: none;
}

.je-modal-backdrop {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(9, 30, 66, 0.54);
}

.je-modal-container {
  position: relative;
  width: 100%;
  max-width: 640px;
  background: #ffffff;
  border-radius: 8px;
  box-shadow: 0 8px 16px rgba(0, 0, 0, 0.25);
  overflow: hidden;
}

.je-modal-header {
  padding: 16px;
  border-bottom: 1px solid #dfe1e6;
}

.je-search-input-wrapper {
  display: flex;
  align-items: center;
  gap: 12px;
}

.je-search-icon {
  color: #6b778c;
  flex-shrink: 0;
}

.je-search-input {
  flex: 1;
  border: none;
  outline: none;
  font-size: 16px;
  color: #172b4d;
  background: transparent;
}

.je-search-input::placeholder {
  color: #97a0af;
}

.je-search-hint {
  font-size: 12px;
  color: #97a0af;
  white-space: nowrap;
}

.je-modal-body {
  max-height: 400px;
  overflow-y: auto;
}

.je-results-list {
  padding: 8px 0;
}

.je-result-item {
  padding: 12px 16px;
  cursor: pointer;
  border-left: 3px solid transparent;
  transition: background 0.1s ease;
}

.je-result-item:hover,
.je-result-item.je-selected {
  background: #f4f5f7;
  border-left-color: #0052cc;
}

.je-result-key {
  font-weight: 600;
  color: #0052cc;
  font-size: 13px;
  margin-bottom: 4px;
}

.je-result-summary {
  color: #172b4d;
  font-size: 14px;
  margin-bottom: 6px;
  line-height: 1.4;
}

.je-result-meta {
  display: flex;
  gap: 12px;
  font-size: 12px;
  color: #6b778c;
}

.je-status {
  padding: 2px 6px;
  border-radius: 3px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
}

.je-status-new { background: #dfe1e6; color: #42526e; }
.je-status-indeterminate { background: #deebff; color: #0052cc; }
.je-status-done { background: #e3fcef; color: #006644; }
.je-status-undefined { background: #f4f5f7; color: #6b778c; }

.je-results-empty,
.je-results-loading,
.je-results-error {
  padding: 32px 16px;
  text-align: center;
  color: #6b778c;
}

.je-results-error {
  color: #de350b;
}

.je-spinner {
  width: 24px;
  height: 24px;
  border: 2px solid #dfe1e6;
  border-top-color: #0052cc;
  border-radius: 50%;
  margin: 0 auto 12px;
  animation: je-spin 0.8s linear infinite;
}

@keyframes je-spin {
  to { transform: rotate(360deg); }
}

.je-modal-footer {
  padding: 12px 16px;
  border-top: 1px solid #dfe1e6;
  background: #f4f5f7;
}

.je-footer-hint {
  font-size: 12px;
  color: #6b778c;
}

.je-footer-hint kbd {
  display: inline-block;
  padding: 2px 6px;
  background: #ffffff;
  border: 1px solid #dfe1e6;
  border-radius: 3px;
  font-family: inherit;
  font-size: 11px;
  margin: 0 2px;
}

/* ===== Utility ===== */
.je-hidden {
  display: none !important;
}
```

---

## 9. Options Page

Allow users to configure API tokens for Server/Data Center and customize settings.

### options.html

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Jira Enhancer Settings</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      padding: 24px;
      max-width: 500px;
      margin: 0 auto;
      color: #172b4d;
    }
    h1 {
      font-size: 20px;
      margin-bottom: 24px;
    }
    .section {
      margin-bottom: 24px;
      padding-bottom: 24px;
      border-bottom: 1px solid #dfe1e6;
    }
    .section:last-child {
      border-bottom: none;
    }
    label {
      display: block;
      font-weight: 600;
      margin-bottom: 8px;
    }
    input[type="text"],
    input[type="password"] {
      width: 100%;
      padding: 8px 12px;
      border: 1px solid #dfe1e6;
      border-radius: 4px;
      font-size: 14px;
      box-sizing: border-box;
    }
    input:focus {
      outline: none;
      border-color: #0052cc;
    }
    .hint {
      font-size: 12px;
      color: #6b778c;
      margin-top: 6px;
    }
    button {
      background: #0052cc;
      color: white;
      border: none;
      padding: 10px 16px;
      border-radius: 4px;
      font-size: 14px;
      cursor: pointer;
    }
    button:hover {
      background: #0065ff;
    }
    .status {
      margin-top: 12px;
      padding: 8px 12px;
      border-radius: 4px;
      font-size: 13px;
    }
    .status.success {
      background: #e3fcef;
      color: #006644;
    }
    .status.error {
      background: #ffebe6;
      color: #de350b;
    }
    .checkbox-row {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 12px;
    }
    .checkbox-row input {
      width: auto;
    }
  </style>
</head>
<body>
  <h1>Jira Enhancer Settings</h1>
  
  <div class="section">
    <label>Jira Server/Data Center URL</label>
    <input type="text" id="serverUrl" placeholder="https://jira.yourcompany.com">
    <p class="hint">Only needed for self-hosted Jira. Leave empty for Jira Cloud.</p>
  </div>
  
  <div class="section">
    <label>API Token (Server/Data Center)</label>
    <input type="password" id="apiToken" placeholder="Personal Access Token">
    <p class="hint">Create a token in Jira: Profile > Personal Access Tokens</p>
  </div>
  
  <div class="section">
    <h3>Features</h3>
    <div class="checkbox-row">
      <input type="checkbox" id="enableFloatingHeader" checked>
      <label for="enableFloatingHeader">Floating title header</label>
    </div>
    <div class="checkbox-row">
      <input type="checkbox" id="enableCopyButtons" checked>
      <label for="enableCopyButtons">Quick copy buttons</label>
    </div>
    <div class="checkbox-row">
      <input type="checkbox" id="enableSearch" checked>
      <label for="enableSearch">Smart search modal</label>
    </div>
  </div>
  
  <button id="save">Save Settings</button>
  <div id="status" class="status" style="display: none;"></div>
  
  <script src="options.js"></script>
</body>
</html>
```

### options.js

```javascript
document.addEventListener('DOMContentLoaded', () => {
  // Load saved settings
  chrome.storage.sync.get([
    'serverUrl',
    'apiToken',
    'enableFloatingHeader',
    'enableCopyButtons',
    'enableSearch'
  ], (result) => {
    document.getElementById('serverUrl').value = result.serverUrl || '';
    document.getElementById('apiToken').value = result.apiToken || '';
    document.getElementById('enableFloatingHeader').checked = result.enableFloatingHeader !== false;
    document.getElementById('enableCopyButtons').checked = result.enableCopyButtons !== false;
    document.getElementById('enableSearch').checked = result.enableSearch !== false;
  });
  
  // Save settings
  document.getElementById('save').addEventListener('click', () => {
    const settings = {
      serverUrl: document.getElementById('serverUrl').value.trim(),
      apiToken: document.getElementById('apiToken').value,
      enableFloatingHeader: document.getElementById('enableFloatingHeader').checked,
      enableCopyButtons: document.getElementById('enableCopyButtons').checked,
      enableSearch: document.getElementById('enableSearch').checked
    };
    
    chrome.storage.sync.set(settings, () => {
      showStatus('Settings saved!', 'success');
      
      // Request permission for custom domain if provided
      if (settings.serverUrl) {
        const url = new URL(settings.serverUrl);
        chrome.permissions.request({
          origins: [`${url.origin}/*`]
        }, (granted) => {
          if (!granted) {
            showStatus('Permission denied for custom domain', 'error');
          }
        });
      }
    });
  });
  
  function showStatus(message, type) {
    const status = document.getElementById('status');
    status.textContent = message;
    status.className = `status ${type}`;
    status.style.display = 'block';
    setTimeout(() => {
      status.style.display = 'none';
    }, 3000);
  }
});
```

---

## 10. Main Entry Point

### content.js (initialization)

```javascript
import JiraSelectors from './lib/jira-selectors.js';
import DOMObserver from './lib/dom-observer.js';
import FloatingHeader from './floating-header.js';
import InlineCopyButtons from './inline-copy.js';
import SearchModal from './search-modal.js';

class JiraEnhancer {
  constructor() {
    this.floatingHeader = new FloatingHeader();
    this.inlineCopy = new InlineCopyButtons();
    this.searchModal = new SearchModal();
  }
  
  async init() {
    // Check if we're on a Jira page
    if (!this.isJiraPage()) {
      return;
    }
    
    // Detect platform
    JiraSelectors.detect();
    
    // Load settings
    const settings = await this.loadSettings();
    
    // Initialize DOM observer
    DOMObserver.init();
    
    // Initialize features based on settings
    if (settings.enableFloatingHeader) {
      this.floatingHeader.init();
    }
    
    if (settings.enableCopyButtons) {
      this.inlineCopy.init();
    }
    
    if (settings.enableSearch) {
      this.searchModal.init();
    }
    
    console.log('[Jira Enhancer] Initialized');
  }
  
  isJiraPage() {
    // Check for Jira-specific elements or URL patterns
    return (
      window.location.hostname.includes('atlassian.net') ||
      document.querySelector('[data-testid*="jira"]') !== null ||
      document.querySelector('#jira') !== null
    );
  }
  
  loadSettings() {
    return new Promise((resolve) => {
      chrome.storage.sync.get([
        'enableFloatingHeader',
        'enableCopyButtons',
        'enableSearch'
      ], (result) => {
        resolve({
          enableFloatingHeader: result.enableFloatingHeader !== false,
          enableCopyButtons: result.enableCopyButtons !== false,
          enableSearch: result.enableSearch !== false
        });
      });
    });
  }
}

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    new JiraEnhancer().init();
  });
} else {
  new JiraEnhancer().init();
}
```

---

## 11. Error Handling Matrix

| Error | Detection | User Feedback | Recovery |
|-------|-----------|---------------|----------|
| Auth required | HTTP 401 | "Please log in to Jira" | Link to login page |
| Rate limited | HTTP 429 | "Too many requests - wait a moment" | Auto-retry after 5s |
| Network failure | Fetch exception | "Unable to connect to Jira" | Retry button |
| Invalid JQL | HTTP 400 | "Search query issue" | Fall back to simpler query |
| DOM selector miss | Element not found | Silent | Retry on next DOM change |
| Clipboard denied | Clipboard API error | Icon turns red briefly | Show manual copy hint |

---

## 12. Testing Plan

### Unit Tests

- JQL builder produces valid queries for edge cases
- Cache TTL expiration works correctly
- HTML escaping prevents XSS

### Integration Tests

- Floating header appears/disappears on scroll
- Copy buttons work for all three types
- Search returns results and handles navigation
- SPA navigation triggers re-injection

### Manual Test Matrix

| Scenario | Jira Cloud | Jira Server | Jira Data Center |
|----------|------------|-------------|------------------|
| View ticket | Test | Test | Test |
| Navigate between tickets | Test | Test | Test |
| Board view | Test | Test | Test |
| Backlog view | Test | Test | Test |
| Search with special chars | Test | Test | Test |
| Search with long title | Test | Test | Test |
| Network offline | Test | Test | Test |
| Session expired | Test | Test | Test |

---

## 13. Security Considerations

- **No sensitive data in storage**: API tokens stored in chrome.storage.sync are encrypted
- **XSS prevention**: All user input and API responses escaped before DOM insertion
- **CORS**: Background service worker handles all API calls to avoid CORS issues
- **Content Security Policy**: Extension does not inject inline scripts
- **Minimal permissions**: Only requests activeTab and clipboardWrite by default

---

## 14. Performance Targets

| Metric | Target |
|--------|--------|
| Time to inject floating header | < 100ms after scroll threshold |
| Search debounce | 300ms |
| Search result display | < 500ms from API response |
| Memory footprint | < 5MB |
| CPU when idle | 0% |

---

## 15. Future Enhancements (Out of Scope v1)

- Bulk copy multiple tickets from board view
- Custom JQL templates/saved searches
- Quick actions (assign, transition) from search results
- Dark mode support
- Firefox/Safari ports

---

## 16. Deployment Checklist

1. Create Chrome Web Store developer account
2. Generate production icons (16, 48, 128px)
3. Write store listing description and screenshots
4. Submit for review
5. Set up automatic update hosting (if self-distributing)
6. Create documentation site for Server/Data Center setup

---

## Appendix A: DOM Selector Reference

Selectors may change with Jira updates. Keep this table updated.

### Jira Cloud (as of March 2026)

| Element | Selector |
|---------|----------|
| Ticket key | `[data-testid="issue.views.issue-base.foundation.breadcrumbs.current-issue.item"] span` |
| Ticket title | `[data-testid="issue.views.issue-base.foundation.summary.heading"]` |
| Main content | `[data-testid="issue.views.issue-details.issue-layout.container-left"]` |

### Jira Server/Data Center

| Element | Selector |
|---------|----------|
| Ticket key | `#key-val, .issue-link` |
| Ticket title | `#summary-val, .issue-header-content h1` |
| Main content | `#details-module, .issue-body-content` |

---

## Appendix B: JQL Quick Reference

| Goal | JQL Pattern |
|------|-------------|
| Exact phrase in summary | `summary ~ "\"exact phrase\""` |
| All terms in summary | `summary ~ "term1" AND summary ~ "term2"` |
| Broad text search | `text ~ "search terms"` |
| By ticket key | `key = "PROJ-1234"` |
| Partial key match | `key ~ "PROJ-12*"` |
| Recent updates | `ORDER BY updated DESC` |
| In project | `project = "PROJ"` |

---

## Contributing

### Getting Started

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run tests: `npm test`
5. Run linter: `npm run lint`
6. Commit with conventional commits: `git commit -m "feat: add new feature"`
7. Push and open a Pull Request

### Commit Convention

We use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Purpose |
|--------|---------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `style:` | Formatting, no code change |
| `refactor:` | Code change that neither fixes nor adds |
| `test:` | Adding or updating tests |
| `chore:` | Build process, dependencies |

### Code Style

- Use ES6+ features
- 2-space indentation
- Single quotes for strings
- No semicolons (handled by linter)
- Meaningful variable names

### Pull Request Guidelines

- One feature/fix per PR
- Update tests if changing behavior
- Update documentation if adding features
- Ensure all checks pass before requesting review

---

## Troubleshooting

### Extension not loading on Jira pages

1. Check that you're on a supported Jira URL (*.atlassian.net or your configured Server URL)
2. Verify extension is enabled in chrome://extensions
3. Check console for errors (F12 > Console)
4. Try reloading the page

### Search returns no results

1. Verify you're logged into Jira
2. Check if the ticket exists with native Jira search
3. Try simpler search terms
4. Check for API rate limiting (wait 1 minute)

### Copy buttons not appearing

1. Wait for page to fully load
2. Check if feature is enabled in extension options
3. Jira may have updated their DOM - report an issue

### Floating header not showing

1. Scroll down past the title area
2. Check if feature is enabled in extension options
3. Try refreshing the page

### Server/Data Center authentication failing

1. Verify your API token is correct
2. Check token hasn't expired
3. Ensure token has required permissions (read access)
4. Verify the server URL includes https://

---

## FAQ

**Q: Does this work with Jira Service Management?**  
A: Yes, JSM uses the same underlying platform as Jira Software.

**Q: Will this slow down Jira?**  
A: No. The extension uses efficient observers and only activates on Jira pages. Idle CPU usage is 0%.

**Q: Is my data sent anywhere?**  
A: No. All API calls go directly to your Jira instance. Nothing is sent to third parties.

**Q: Can I use this with multiple Jira instances?**  
A: Yes for Cloud instances (automatic). For Server, you can only configure one instance currently.

**Q: Why Ctrl+Shift+K instead of Ctrl+K?**  
A: Ctrl+K conflicts with browser features, Jira native shortcuts, and other apps like Slack.

---

## Changelog

### [1.0.0] - 2026-03-11

#### Added
- Floating title header with ticket key and title
- Quick copy buttons for ticket key, title, and URL
- Smart search modal with three-tier JQL fallback
- Support for Jira Cloud and Server/Data Center
- Options page for configuration
- Keyboard shortcut (Ctrl+Shift+K / Cmd+Shift+K)

#### Technical
- MutationObserver for SPA navigation handling
- 60-second result caching
- Platform auto-detection
- Modular architecture with centralized selectors

---

## Roadmap

### v1.1 (Planned)
- [ ] Dark mode support
- [ ] Customizable keyboard shortcuts
- [ ] Copy format templates (Markdown, plain text)

### v1.2 (Planned)
- [ ] Quick actions from search (assign, transition)
- [ ] Saved search queries
- [ ] Board view bulk copy

### v2.0 (Future)
- [ ] Firefox port
- [ ] Safari port
- [ ] Multiple Server instance support

---

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Support

- **Issues**: [GitHub Issues](https://github.com/yourorg/jira-enhancer/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourorg/jira-enhancer/discussions)
- **Email**: support@yourorg.com

---

## Acknowledgments

- Atlassian for the Jira REST API documentation
- Chrome Extensions team for Manifest V3
- All contributors and testers
