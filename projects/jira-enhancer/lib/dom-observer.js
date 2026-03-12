class JiraDOMObserver {
  constructor() {
    this.observer = null
    this.callbacks = new Map()
    this.lastUrl = window.location.href
  }

  init() {
    // Watch for DOM changes
    this.observer = new MutationObserver((mutations) => {
      this.handleMutations(mutations)
    })

    this.observer.observe(document.body, {
      childList: true,
      subtree: true
    })

    // Watch for SPA navigation (URL changes without page reload)
    this.startUrlWatcher()
  }

  startUrlWatcher() {
    // Jira uses history API for navigation
    const originalPushState = history.pushState
    const originalReplaceState = history.replaceState

    history.pushState = (...args) => {
      originalPushState.apply(history, args)
      this.handleNavigation()
    }

    history.replaceState = (...args) => {
      originalReplaceState.apply(history, args)
      this.handleNavigation()
    }

    window.addEventListener('popstate', () => this.handleNavigation())
  }

  handleNavigation() {
    if (window.location.href !== this.lastUrl) {
      this.lastUrl = window.location.href
      this.callbacks.forEach((callback) => {
        if (callback.onNavigate) {
          callback.onNavigate()
        }
      })
    }
  }

  handleMutations(mutations) {
    // Debounce to avoid excessive re-runs
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => {
      this.callbacks.forEach((callback) => {
        if (callback.onDOMChange) {
          callback.onDOMChange(mutations)
        }
      })
    }, 100)
  }

  register(name, callbacks) {
    this.callbacks.set(name, callbacks)
  }

  unregister(name) {
    this.callbacks.delete(name)
  }

  destroy() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }
}

// exported as global for content scripts
window.DOMObserver = new JiraDOMObserver()
