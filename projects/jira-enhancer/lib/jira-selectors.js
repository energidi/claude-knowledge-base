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

  // Selectors differ by platform
  get ticketTitle() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-base.foundation.summary.heading"]'
      : '#summary-val, .issue-header-content h1'
  },

  get ticketKey() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-base.foundation.breadcrumbs.current-issue.item"] span'
      : '#key-val, .issue-link'
  },

  get mainContent() {
    return this.platform === 'cloud'
      ? '[data-testid="issue.views.issue-details.issue-layout.container-left"]'
      : '#details-module, .issue-body-content'
  },

  // API base URL
  get apiBase() {
    if (this.platform === 'cloud') {
      return `/rest/api/3`
    }
    return `/rest/api/2`
  }
}

export default JiraSelectors
