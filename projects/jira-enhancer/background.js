import SimpleCache from './lib/cache.js'
import JQLBuilder from './lib/jql-builder.js'

const cache = new SimpleCache(60000) // 60 second TTL

// Listen for search requests from content script
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'search') {
    handleSearch(request, sender.tab)
      .then(sendResponse)
      .catch(err => sendResponse({ error: err.message }))
    return true // Keep channel open for async response
  }

  if (request.action === 'getAuthStatus') {
    checkAuthStatus(request.domain)
      .then(sendResponse)
      .catch(err => sendResponse({ error: err.message }))
    return true
  }
})

async function handleSearch({ query, domain, apiVersion, projectKey }) {
  // Check cache first
  const cacheKey = `${domain}:${query}:${projectKey || 'all'}`
  const cached = cache.get(cacheKey)
  if (cached) {
    return { results: cached, fromCache: true }
  }

  // Build smart JQL
  const jql = JQLBuilder.isTicketKey(query)
    ? JQLBuilder.buildKeySearch(query)
    : JQLBuilder.build(query, projectKey)

  // Try primary query first
  let results = await executeSearch(domain, apiVersion, JQLBuilder.isTicketKey(query) ? jql + ' ORDER BY updated DESC' : jql.primary + jql.orderBy)

  // Fallback if no results
  if (results.length === 0 && !JQLBuilder.isTicketKey(query)) {
    results = await executeSearch(domain, apiVersion, jql.fallback + jql.orderBy)
  }

  // Broad search as last resort
  if (results.length === 0 && !JQLBuilder.isTicketKey(query)) {
    results = await executeSearch(domain, apiVersion, jql.broad + jql.orderBy)
  }

  // Cache results
  cache.set(cacheKey, results)

  return { results, fromCache: false }
}

async function executeSearch(domain, apiVersion, jql) {
  const baseUrl = `https://${domain}/rest/api/${apiVersion}`
  const url = `${baseUrl}/search?jql=${encodeURIComponent(jql)}&maxResults=10&fields=key,summary,status,assignee,updated`

  try {
    const response = await fetch(url, {
      method: 'GET',
      credentials: 'include', // Send cookies for auth
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      }
    })

    if (response.status === 401) {
      throw new Error('AUTH_REQUIRED')
    }

    if (response.status === 429) {
      throw new Error('RATE_LIMITED')
    }

    if (!response.ok) {
      throw new Error(`API_ERROR:${response.status}`)
    }

    const data = await response.json()

    return data.issues.map(issue => ({
      key: issue.key,
      summary: issue.fields.summary,
      status: issue.fields.status?.name || 'Unknown',
      statusCategory: issue.fields.status?.statusCategory?.key || 'undefined',
      assignee: issue.fields.assignee?.displayName || 'Unassigned',
      updated: issue.fields.updated,
      url: `https://${domain}/browse/${issue.key}`
    }))

  } catch (err) {
    if (err.message.startsWith('AUTH') || err.message.startsWith('RATE') || err.message.startsWith('API')) {
      throw err
    }
    throw new Error('NETWORK_ERROR')
  }
}

async function checkAuthStatus(domain) {
  try {
    const response = await fetch(`https://${domain}/rest/api/3/myself`, {
      credentials: 'include'
    })
    return { authenticated: response.ok }
  } catch {
    return { authenticated: false }
  }
}
