class JQLBuilder {
  constructor() {
    // Characters that break JQL
    this.specialChars = /[+\-&|!(){}[\]^"~*?:\\]/g
  }

  /**
   * Build a smart JQL query with fallback strategies
   * @param {string} input - User's search text
   * @param {string} projectKey - Optional project filter
   * @returns {object} - { primary: string, fallback: string }
   */
  build(input, projectKey = null) {
    const sanitized = this.sanitize(input)
    const terms = this.tokenize(sanitized)

    let projectFilter = projectKey ? `project = "${projectKey}" AND ` : ''

    // Strategy 1: Exact phrase match (works best for copy-pasted titles)
    const primary = `${projectFilter}summary ~ "\\"${sanitized}\\""`

    // Strategy 2: AND-chained terms (fallback if exact match returns nothing)
    // Guard: if all words were stop words, fall back to the full sanitized string
    const termClauses = terms.length > 0
      ? terms.map(term => `summary ~ "${term}"`).join(' AND ')
      : `summary ~ "${sanitized}"`
    const fallback = `${projectFilter}${termClauses}`

    // Strategy 3: Broad text search (last resort)
    const broad = `${projectFilter}text ~ "${sanitized}"`

    return {
      primary,
      fallback,
      broad,
      orderBy: ' ORDER BY updated DESC'
    }
  }

  sanitize(input) {
    return input
      .trim()
      .replace(this.specialChars, ' ')
      .replace(/\s+/g, ' ')
  }

  tokenize(input) {
    // Split into words, filter out short/common words
    const stopWords = ['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'for', 'on', 'with']
    return input
      .toLowerCase()
      .split(' ')
      .filter(word => word.length > 2 && !stopWords.includes(word))
  }

  /**
   * Build query for ticket key search (PROJ-1234)
   */
  buildKeySearch(key) {
    // Direct key match
    if (/^[A-Z]+-\d+$/i.test(key)) {
      return `key = "${key.toUpperCase()}"`
    }
    // Partial key search
    return `key ~ "${key.toUpperCase()}*"`
  }

  /**
   * Detect if input looks like a ticket key
   */
  isTicketKey(input) {
    return /^[A-Z]{2,10}-\d+$/i.test(input.trim())
  }
}

// exported as global for content scripts
window.JQLBuilder = new JQLBuilder()
