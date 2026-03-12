class InlineCopyButtons {
  constructor() {
    this.injected = false
  }

  init() {
    window.DOMObserver.register('inlineCopy', {
      onNavigate: () => this.reinject(),
      onDOMChange: () => this.injectIfNeeded()
    })

    this.injectIfNeeded()
  }

  injectIfNeeded() {
    if (this.injected) return

    const key = window.JiraSelectors.currentKey()
    const titleElement = document.querySelector(window.JiraSelectors.ticketTitle)

    // Inject key copy button next to the title if we have a key and a title element
    if (key && titleElement && !titleElement.parentElement.querySelector('.je-inline-copy[data-type="key"]')) {
      this.addCopyButton(titleElement.parentElement, 'key')
    }

    if (titleElement && !titleElement.parentElement.querySelector('.je-inline-copy[data-type="title"]')) {
      this.addCopyButton(titleElement.parentElement, 'title')
    }

    if (key && titleElement) {
      this.injected = true
    }
  }

  addCopyButton(container, type) {
    const btn = document.createElement('button')
    btn.className = 'je-inline-copy'
    btn.dataset.type = type
    btn.title = `Copy ${type}`
    btn.innerHTML = `
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
      </svg>
    `

    btn.addEventListener('click', async (e) => {
      e.preventDefault()
      e.stopPropagation()

      let text = ''
      if (type === 'key') {
        text = window.JiraSelectors.currentKey() || ''
      } else {
        text = document.querySelector(window.JiraSelectors.ticketTitle)?.textContent.trim() || ''
      }

      if (text) {
        try {
          await navigator.clipboard.writeText(text)
          btn.classList.add('je-copy-success')
        } catch {
          btn.classList.add('je-copy-error')
        }
        setTimeout(() => btn.classList.remove('je-copy-success', 'je-copy-error'), 1000)
      }
    })

    container.appendChild(btn)
  }

  reinject() {
    this.injected = false
    document.querySelectorAll('.je-inline-copy').forEach(el => el.remove())
    setTimeout(() => this.injectIfNeeded(), 500)
  }
}

// global for content scripts
window.InlineCopyButtons = InlineCopyButtons
