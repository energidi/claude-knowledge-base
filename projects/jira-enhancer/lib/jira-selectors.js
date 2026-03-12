const JiraSelectors = {
  platform: null,

  detect() {
    // Cloud uses atlassian.net domain
    if (window.location.hostname.includes('atlassian.net')) {
      this.platform = 'cloud'
    } else {
      this.platform = 'server'
    }
    return this.platform
  },

  // Selectors differ by platform.
  // Cloud selectors are listed most-specific first; querySelector picks the first match.
  get ticketTitle() {
    return this.platform === 'cloud'
      ? [
          '[data-testid="issue.views.issue-base.foundation.summary.heading"]',
          '[data-testid*="summary.heading"]',
          'h1[data-testid*="summary"]',
          '[data-component-selector*="summary"] h1',
          'h1[class*="summary"]',
          '#summary-val',
        ].join(', ')
      : '#summary-val, .issue-header-content h1'
  },

  get ticketKey() {
    return this.platform === 'cloud'
      ? [
          '[data-testid="issue.views.issue-base.foundation.breadcrumbs.current-issue.item"] span',
          '[data-testid*="current-issue"] span',
          '[data-testid*="breadcrumb"] [data-testid*="issue"] span',
        ].join(', ')
      : '#key-val, .issue-link'
  },

  get mainContent() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-details.issue-layout.container-left"]'
      : '#details-module, .issue-body-content'
  },

  // Extract ticket key from URL — more reliable than any DOM selector
  // Works for /browse/PROJ-123 and /issues/PROJ-123 style URLs
  currentKey() {
    const m = window.location.pathname.match(/\/(?:browse|issues)\/([A-Z]+-\d+)/i)
    return m ? m[1].toUpperCase() : null
  },

  // API base URL
  get apiBase() {
    if (this.platform === 'cloud') {
      return `/rest/api/3`
    }
    return `/rest/api/2`
  }
}

// exported as global for content scripts
window.JiraSelectors = JiraSelectors
