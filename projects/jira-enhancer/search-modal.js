class SearchModal {
  constructor() {
    this.modal = null
    this.input = null
    this.results = null
    this.selectedIndex = -1
    this.searchResults = []
    this.debounceTimer = null
    this.isOpen = false
  }

  init() {
    this.createModal()
    this.attachListeners()

    // Listen for keyboard shortcut from background
    chrome.runtime.onMessage.addListener((request) => {
      if (request.action === 'openSearch') {
        this.open()
      }
    })

    // Also listen for direct keyboard events (backup)
    document.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'K') {
        e.preventDefault()
        this.toggle()
      }

      if (e.key === 'Escape' && this.isOpen) {
        this.close()
      }
    })
  }

  createModal() {
    this.modal = document.createElement('div')
    this.modal.id = 'je-search-modal'
    this.modal.className = 'je-modal je-hidden'
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
    `

    document.body.appendChild(this.modal)

    this.input = this.modal.querySelector('.je-search-input')
    this.results = this.modal.querySelector('.je-results-list')
    this.emptyState = this.modal.querySelector('.je-results-empty')
    this.loadingState = this.modal.querySelector('.je-results-loading')
    this.errorState = this.modal.querySelector('.je-results-error')
  }

  attachListeners() {
    // Close on backdrop click
    this.modal.querySelector('.je-modal-backdrop').addEventListener('click', () => {
      this.close()
    })

    // Input handling
    this.input.addEventListener('input', () => {
      this.handleInput()
    })

    // Keyboard navigation
    this.input.addEventListener('keydown', (e) => {
      this.handleKeydown(e)
    })
  }

  handleInput() {
    const query = this.input.value.trim()

    clearTimeout(this.debounceTimer)

    if (query.length < 2) {
      this.clearResults()
      return
    }

    this.showLoading()

    this.debounceTimer = setTimeout(() => {
      this.search(query)
    }, 300)
  }

  async search(query) {
    const domain = window.location.hostname
    const apiVersion = domain.includes('atlassian.net') ? '3' : '2'

    try {
      const response = await chrome.runtime.sendMessage({
        action: 'search',
        query,
        domain,
        apiVersion
      })

      if (response.error) {
        this.showError(response.error)
        return
      }

      this.searchResults = response.results
      this.renderResults()

    } catch (err) {
      this.showError('NETWORK_ERROR')
    }
  }

  renderResults() {
    this.hideLoading()

    if (this.searchResults.length === 0) {
      this.emptyState.classList.remove('je-hidden')
      this.results.innerHTML = ''
      return
    }

    this.emptyState.classList.add('je-hidden')
    this.selectedIndex = 0

    this.results.innerHTML = this.searchResults.map((result, index) => `
      <div class="je-result-item ${index === 0 ? 'je-selected' : ''}" data-index="${index}">
        <div class="je-result-key">${this.escapeHtml(result.key)}</div>
        <div class="je-result-summary">${this.escapeHtml(result.summary)}</div>
        <div class="je-result-meta">
          <span class="je-status je-status-${result.statusCategory}">${this.escapeHtml(result.status)}</span>
          <span class="je-assignee">${this.escapeHtml(result.assignee)}</span>
        </div>
      </div>
    `).join('')

    // Click handlers for results
    this.results.querySelectorAll('.je-result-item').forEach((item) => {
      item.addEventListener('click', (e) => {
        const index = parseInt(item.dataset.index)
        this.openResult(index, e.ctrlKey || e.metaKey)
      })

      item.addEventListener('mouseenter', () => {
        this.selectResult(parseInt(item.dataset.index))
      })
    })
  }

  handleKeydown(e) {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault()
        this.selectResult(this.selectedIndex + 1)
        break

      case 'ArrowUp':
        e.preventDefault()
        this.selectResult(this.selectedIndex - 1)
        break

      case 'Enter':
        e.preventDefault()
        if (this.selectedIndex >= 0) {
          this.openResult(this.selectedIndex, e.ctrlKey || e.metaKey)
        }
        break
    }
  }

  selectResult(index) {
    if (index < 0) index = this.searchResults.length - 1
    if (index >= this.searchResults.length) index = 0

    this.selectedIndex = index

    this.results.querySelectorAll('.je-result-item').forEach((item, i) => {
      item.classList.toggle('je-selected', i === index)
    })

    // Scroll into view
    const selected = this.results.querySelector('.je-selected')
    if (selected) {
      selected.scrollIntoView({ block: 'nearest' })
    }
  }

  openResult(index, newTab = false) {
    const result = this.searchResults[index]
    if (!result) return

    if (newTab) {
      window.open(result.url, '_blank')
    } else {
      window.location.href = result.url
    }

    this.close()
  }

  showLoading() {
    this.loadingState.classList.remove('je-hidden')
    this.emptyState.classList.add('je-hidden')
    this.errorState.classList.add('je-hidden')
  }

  hideLoading() {
    this.loadingState.classList.add('je-hidden')
  }

  showError(errorCode) {
    this.hideLoading()
    this.emptyState.classList.add('je-hidden')
    this.errorState.classList.remove('je-hidden')

    const messages = {
      'AUTH_REQUIRED': 'Please log in to Jira to search',
      'RATE_LIMITED': 'Too many requests - please wait a moment',
      'NETWORK_ERROR': 'Unable to connect to Jira',
      'API_ERROR': 'Jira returned an error'
    }

    this.errorState.textContent = messages[errorCode] || 'An error occurred'
  }

  clearResults() {
    this.results.innerHTML = ''
    this.emptyState.classList.add('je-hidden')
    this.errorState.classList.add('je-hidden')
    this.searchResults = []
    this.selectedIndex = -1
  }

  open() {
    this.modal.classList.remove('je-hidden')
    this.input.focus()
    this.input.select()
    this.isOpen = true
    document.body.style.overflow = 'hidden'
  }

  close() {
    this.modal.classList.add('je-hidden')
    this.input.value = ''
    this.clearResults()
    this.isOpen = false
    document.body.style.overflow = ''
  }

  toggle() {
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

export default SearchModal
