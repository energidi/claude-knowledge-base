import JiraSelectors from './lib/jira-selectors.js'
import DOMObserver from './lib/dom-observer.js'

class FloatingHeader {
  constructor() {
    this.header = null
    this.titleObserver = null
    this.isVisible = false
  }

  init() {
    JiraSelectors.detect()
    this.createHeader()
    this.setupIntersectionObserver()

    DOMObserver.register('floatingHeader', {
      onNavigate: () => this.reinject(),
      onDOMChange: () => this.checkTitleExists()
    })
  }

  createHeader() {
    // Remove existing if present
    const existing = document.getElementById('jira-enhancer-header')
    if (existing) existing.remove()

    this.header = document.createElement('div')
    this.header.id = 'jira-enhancer-header'
    this.header.className = 'je-floating-header je-hidden'
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
    `

    document.body.appendChild(this.header)
    this.attachCopyListeners()
  }

  setupIntersectionObserver() {
    // Wait for title element to exist
    this.waitForElement(JiraSelectors.ticketTitle, (titleElement) => {
      this.updateHeaderContent()

      this.titleObserver = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) {
              this.hide()
            } else if (entry.boundingClientRect.top < 0) {
              this.show()
            }
          })
        },
        { threshold: 0, rootMargin: '-60px 0px 0px 0px' }
      )

      this.titleObserver.observe(titleElement)
    })
  }

  waitForElement(selector, callback, maxAttempts = 50) {
    let attempts = 0
    const check = () => {
      const element = document.querySelector(selector)
      if (element) {
        callback(element)
      } else if (attempts < maxAttempts) {
        attempts++
        setTimeout(check, 100)
      }
    }
    check()
  }

  updateHeaderContent() {
    const keyElement = document.querySelector(JiraSelectors.ticketKey)
    const titleElement = document.querySelector(JiraSelectors.ticketTitle)

    if (keyElement && titleElement) {
      this.header.querySelector('.je-ticket-key').textContent = keyElement.textContent.trim()
      this.header.querySelector('.je-ticket-title').textContent = titleElement.textContent.trim()
    }
  }

  show() {
    if (!this.isVisible) {
      this.header.classList.remove('je-hidden')
      this.isVisible = true
    }
  }

  hide() {
    if (this.isVisible) {
      this.header.classList.add('je-hidden')
      this.isVisible = false
    }
  }

  reinject() {
    // Disconnect old observer
    if (this.titleObserver) {
      this.titleObserver.disconnect()
      this.titleObserver = null
    }
    this.hide()

    // Re-setup after navigation
    setTimeout(() => {
      this.setupIntersectionObserver()
    }, 500)
  }

  checkTitleExists() {
    const titleElement = document.querySelector(JiraSelectors.ticketTitle)
    if (titleElement && !this.titleObserver) {
      this.setupIntersectionObserver()
    }
  }

  attachCopyListeners() {
    this.header.querySelectorAll('.je-copy-btn').forEach((btn) => {
      btn.addEventListener('click', (e) => {
        e.preventDefault()
        const copyType = btn.dataset.copy
        this.handleCopy(copyType, btn)
      })
    })
  }

  async handleCopy(type, button) {
    const keyElement = document.querySelector(JiraSelectors.ticketKey)
    const titleElement = document.querySelector(JiraSelectors.ticketTitle)

    let text = ''
    switch (type) {
      case 'key':
        text = keyElement?.textContent.trim() || ''
        break
      case 'title':
        text = titleElement?.textContent.trim() || ''
        break
      case 'url':
        text = window.location.href.split('?')[0]
        break
    }

    if (text) {
      try {
        await navigator.clipboard.writeText(text)
        this.showCopyFeedback(button, true)
      } catch (err) {
        this.showCopyFeedback(button, false)
      }
    }
  }

  showCopyFeedback(button, success) {
    button.classList.add(success ? 'je-copy-success' : 'je-copy-error')
    setTimeout(() => {
      button.classList.remove('je-copy-success', 'je-copy-error')
    }, 1000)
  }
}

export default FloatingHeader
