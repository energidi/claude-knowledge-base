document.addEventListener('DOMContentLoaded', () => {
  // Load saved settings
  chrome.storage.sync.get([
    'serverUrl',
    'apiToken',
    'enableFloatingHeader',
    'enableCopyButtons',
    'enableSearch'
  ], (result) => {
    document.getElementById('serverUrl').value = result.serverUrl || ''
    document.getElementById('apiToken').value = result.apiToken || ''
    document.getElementById('enableFloatingHeader').checked = result.enableFloatingHeader !== false
    document.getElementById('enableCopyButtons').checked = result.enableCopyButtons !== false
    document.getElementById('enableSearch').checked = result.enableSearch !== false
  })

  // Save settings
  document.getElementById('save').addEventListener('click', () => {
    const settings = {
      serverUrl: document.getElementById('serverUrl').value.trim(),
      apiToken: document.getElementById('apiToken').value,
      enableFloatingHeader: document.getElementById('enableFloatingHeader').checked,
      enableCopyButtons: document.getElementById('enableCopyButtons').checked,
      enableSearch: document.getElementById('enableSearch').checked
    }

    // Validate serverUrl before saving
    if (settings.serverUrl) {
      try {
        new URL(settings.serverUrl)
      } catch {
        showStatus('Invalid server URL — include https://', 'error')
        return
      }
    }

    chrome.storage.sync.set(settings, () => {
      showStatus('Settings saved!', 'success')

      // Request permission for custom domain if provided
      if (settings.serverUrl) {
        const url = new URL(settings.serverUrl)
        chrome.permissions.request({
          origins: [`${url.origin}/*`]
        }, (granted) => {
          if (!granted) {
            showStatus('Permission denied for custom domain', 'error')
          }
        })
      }
    })
  })

  function showStatus(message, type) {
    const status = document.getElementById('status')
    status.textContent = message
    status.className = `status ${type}`
    status.style.display = 'block'
    setTimeout(() => {
      status.style.display = 'none'
    }, 3000)
  }
})
