class SearchModal {
  constructor() {
    this.bar = null
    this.input = null
    this.results = null
    this.selectedIndex = -1
    this.searchResults = []
    this.debounceTimer = null
  }

  init() {
    this.createBar()
    this.attachListeners()

    // Ctrl+Shift+K focuses the search bar
    chrome.runtime.onMessage.addListener((request) => {
      if (request.action === 'openSearch') {
        this.focus()
      }
    })

    document.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'K') {
        e.preventDefault()
        this.focus()
      }
      if (e.key === 'Escape' && document.activeElement === this.input) {
        this.input.blur()
        this.closeDropdown()
      }
    })
  }

  createBar() {
    this.bar = document.createElement('div')
    this.bar.id = 'je-search-bar'
    this.bar.innerHTML = `
      <div class="je-searchbar-input-wrapper">
        <svg class="je-search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="8"></circle>
          <path d="m21 21-4.35-4.35"></path>
        </svg>
        <input type="text" class="je-searchbar-input" placeholder="Search Jira… (Ctrl+Shift+K)" autocomplete="off" />
      </div>
      <div class="je-searchbar-dropdown je-hidden">
        <div class="je-results-list"></div>
        <div class="je-results-empty je-hidden">No results found</div>
        <div class="je-results-loading je-hidden">
          <div class="je-spinner"></div>
          Searching...
        </div>
        <div class="je-results-error je-hidden"></div>
        <div class="je-searchbar-footer">
          <kbd>↑</kbd><kbd>↓</kbd> Navigate &nbsp; <kbd>Enter</kbd> Open &nbsp; <kbd>Ctrl+Enter</kbd> New tab
        </div>
      </div>
    `

    document.body.appendChild(this.bar)

    this.input = this.bar.querySelector('.je-searchbar-input')
    this.dropdown = this.bar.querySelector('.je-searchbar-dropdown')
    this.results = this.bar.querySelector('.je-results-list')
    this.emptyState = this.bar.querySelector('.je-results-empty')
    this.loadingState = this.bar.querySelector('.je-results-loading')
    this.errorState = this.bar.querySelector('.je-results-error')
  }

  attachListeners() {
    this.input.addEventListener('input', () => this.handleInput())
    this.input.addEventListener('keydown', (e) => this.handleKeydown(e))
    this.input.addEventListener('focus', () => {
      if (this.searchResults.length > 0) {
        this.dropdown.classList.remove('je-hidden')
      } else if (this.input.value.trim().length === 0) {
        this.loadRecent()
      }
    })

    // Close dropdown when clicking outside
    document.addEventListener('click', (e) => {
      if (!this.bar.contains(e.target)) {
        this.closeDropdown()
      }
    })
  }

  focus() {
    this.input.focus()
    this.input.select()
  }

  handleInput() {
    const query = this.input.value.trim()
    clearTimeout(this.debounceTimer)

    if (query.length === 0) {
      this.loadRecent()
      return
    }

    if (query.length < 2) {
      this.clearResults()
      return
    }

    this.showLoading()

    this.debounceTimer = setTimeout(() => {
      this.search(query)
    }, 300)
  }

  loadRecent() {
    this.showLoading()
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this.search(''), 150)
  }

  async search(query) {
    const apiVersion = window.location.hostname.includes('atlassian.net') ? '3' : '2'

    try {
      let jql
      if (!query) {
        jql = 'ORDER BY updated DESC'
      } else if (window.JQLBuilder.isTicketKey(query)) {
        jql = window.JQLBuilder.buildKeySearch(query) + ' ORDER BY updated DESC'
      } else {
        const built = window.JQLBuilder.build(query)
        jql = built.primary + built.orderBy
      }

      const url = `/rest/api/${apiVersion}/search?jql=${encodeURIComponent(jql)}&maxResults=10&fields=key,summary,status,assignee`

      const response = await fetch(url, {
        credentials: 'include',
        headers: { 'Accept': 'application/json' }
      })

      if (response.status === 401) { this.showError('AUTH_REQUIRED'); return }
      if (!response.ok) { this.showError('API_ERROR:' + response.status); return }

      const data = await response.json()

      // If exact phrase returned nothing, retry with AND-chained terms
      if (data.issues.length === 0 && query && !window.JQLBuilder.isTicketKey(query)) {
        const built = window.JQLBuilder.build(query)
        const fallbackUrl = `/rest/api/${apiVersion}/search?jql=${encodeURIComponent(built.fallback + built.orderBy)}&maxResults=10&fields=key,summary,status,assignee`
        const fallbackResp = await fetch(fallbackUrl, { credentials: 'include', headers: { 'Accept': 'application/json' } })
        if (fallbackResp.ok) {
          const fallbackData = await fallbackResp.json()
          data.issues = fallbackData.issues
        }
      }

      this.searchResults = data.issues.map(issue => ({
        key: issue.key,
        summary: issue.fields.summary,
        status: issue.fields.status?.name || 'Unknown',
        statusCategory: issue.fields.status?.statusCategory?.key || 'undefined',
        assignee: issue.fields.assignee?.displayName || 'Unassigned',
        url: `/browse/${issue.key}`
      }))
      this.renderResults()

    } catch (err) {
      this.showError('NETWORK_ERROR')
    }
  }

  renderResults() {
    this.hideLoading()
    this.dropdown.classList.remove('je-hidden')

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

    this.results.querySelectorAll('.je-result-item').forEach((item) => {
      item.addEventListener('click', (e) => {
        this.openResult(parseInt(item.dataset.index), e.ctrlKey || e.metaKey)
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
    const selected = this.results.querySelector('.je-selected')
    if (selected) selected.scrollIntoView({ block: 'nearest' })
  }

  openResult(index, newTab = false) {
    const result = this.searchResults[index]
    if (!result) return
    if (newTab) {
      window.open(result.url, '_blank')
    } else {
      window.location.href = result.url
    }
    this.input.value = ''
    this.closeDropdown()
  }

  closeDropdown() {
    this.dropdown.classList.add('je-hidden')
  }

  showLoading() {
    this.dropdown.classList.remove('je-hidden')
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
      'RATE_LIMITED': 'Too many requests — wait a moment',
      'NETWORK_ERROR': 'Unable to connect to Jira',
      'API_ERROR': 'Jira API error — try adding an API token in extension settings'
    }
    // errorCode may include a status suffix like 'API_ERROR:403'
    const key = errorCode.split(':')[0]
    this.errorState.textContent = messages[key] || messages[errorCode] || `Search error: ${errorCode}`
  }

  clearResults() {
    this.results.innerHTML = ''
    this.emptyState.classList.add('je-hidden')
    this.errorState.classList.add('je-hidden')
    this.searchResults = []
    this.selectedIndex = -1
    this.closeDropdown()
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}

// global for content scripts
window.SearchModal = SearchModal
