class JiraEnhancer {
  constructor() {
    this.floatingHeader = new window.FloatingHeader()
    this.inlineCopy = new window.InlineCopyButtons()
    this.searchModal = new window.SearchModal()
  }

  async init() {
    // Check if we're on a Jira page
    if (!this.isJiraPage()) {
      return
    }

    // Detect platform
    window.JiraSelectors.detect()

    // Load settings
    const settings = await this.loadSettings()

    // Initialize DOM observer
    window.DOMObserver.init()

    // Initialize features based on settings
    if (settings.enableFloatingHeader) {
      this.floatingHeader.init()
    }

    if (settings.enableCopyButtons) {
      this.inlineCopy.init()
    }

    if (settings.enableSearch) {
      this.searchModal.init()
    }

    console.log('[Jira Enhancer] Initialized')
  }

  isJiraPage() {
    // Check for Jira-specific elements or URL patterns
    return (
      window.location.hostname.includes('atlassian.net') ||
      document.querySelector('[data-testid*="jira"]') !== null ||
      document.querySelector('#jira') !== null
    )
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
        })
      })
    })
  }
}

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', () => {
    new JiraEnhancer().init()
  })
} else {
  new JiraEnhancer().init()
}
