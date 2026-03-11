import JiraSelectors from './lib/jira-selectors.js'
import DOMObserver from './lib/dom-observer.js'

class InlineCopyButtons {
  constructor() {
    this.injected = false
  }

  init() {
    DOMObserver.register('inlineCopy', {
      onNavigate: () => this.reinject(),
      onDOMChange: () => this.injectIfNeeded()
    })

    this.injectIfNeeded()
  }

  injectIfNeeded() {
    if (this.injected) return

    const keyElement = document.querySelector(JiraSelectors.ticketKey)
    const titleElement = document.querySelector(JiraSelectors.ticketTitle)

    if (keyElement && !keyElement.querySelector('.je-inline-copy')) {
      this.addCopyButton(keyElement, 'key')
    }

    if (titleElement && !titleElement.parentElement.querySelector('.je-inline-copy')) {
      this.addCopyButton(titleElement.parentElement, 'title')
    }

    if (keyElement && titleElement) {
      this.injected = true
    }
  }

  addCopyButton(container, type) {
    const btn = document.createElement('button')
    btn.className = 'je-inline-copy'
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
        text = document.querySelector(JiraSelectors.ticketKey)?.textContent.trim()
      } else {
        text = document.querySelector(JiraSelectors.ticketTitle)?.textContent.trim()
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

export default InlineCopyButtons
