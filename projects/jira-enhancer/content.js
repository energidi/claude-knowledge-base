import JiraSelectors from './lib/jira-selectors.js'
import DOMObserver from './lib/dom-observer.js'
import FloatingHeader from './floating-header.js'
import InlineCopyButtons from './inline-copy.js'
import SearchModal from './search-modal.js'

class JiraEnhancer {
  constructor() {
    this.floatingHeader = new FloatingHeader()
    this.inlineCopy = new InlineCopyButtons()
    this.searchModal = new SearchModal()
  }

  async init() {
    // Check if we're on a Jira page
    if (!this.isJiraPage()) {
      return
    }

    // Detect platform
    JiraSelectors.detect()

    // Load settings
    const settings = await this.loadSettings()

    // Initialize DOM observer
    DOMObserver.init()

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
