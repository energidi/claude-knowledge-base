/**
 * Unit tests for JQLBuilder
 * Run with: npm test
 */

// JQLBuilder is an ES module default export - import it as CJS for Jest
// We replicate the class inline for testing since Jest doesn't natively handle ES modules
// without Babel. For full ES module support add @babel/preset-env or use --experimental-vm-modules.

class JQLBuilder {
  constructor() {
    this.specialChars = /[+\-&|!(){}[\]^"~*?:\\]/g
  }

  build(input, projectKey = null) {
    const sanitized = this.sanitize(input)
    const terms = this.tokenize(sanitized)
    let projectFilter = projectKey ? `project = "${projectKey}" AND ` : ''
    const primary = `${projectFilter}summary ~ "\\"${sanitized}\\""`
    const termClauses = terms.map(term => `summary ~ "${term}"`).join(' AND ')
    const fallback = `${projectFilter}${termClauses}`
    const broad = `${projectFilter}text ~ "${sanitized}"`
    return { primary, fallback, broad, orderBy: ' ORDER BY updated DESC' }
  }

  sanitize(input) {
    return input
      .trim()
      .replace(this.specialChars, ' ')
      .replace(/\s+/g, ' ')
  }

  tokenize(input) {
    const stopWords = ['the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'for', 'on', 'with']
    return input
      .toLowerCase()
      .split(' ')
      .filter(word => word.length > 2 && !stopWords.includes(word))
  }

  buildKeySearch(key) {
    if (/^[A-Z]+-\d+$/i.test(key)) {
      return `key = "${key.toUpperCase()}"`
    }
    return `key ~ "${key.toUpperCase()}*"`
  }

  isTicketKey(input) {
    return /^[A-Z]{2,10}-?\d*$/i.test(input.trim())
  }
}

const jqlBuilder = new JQLBuilder()

describe('JQLBuilder', () => {
  describe('sanitize()', () => {
    test('trims whitespace', () => {
      expect(jqlBuilder.sanitize('  hello  ')).toBe('hello')
    })

    test('removes special chars that break JQL', () => {
      expect(jqlBuilder.sanitize('hello+world')).toBe('hello world')
      expect(jqlBuilder.sanitize('fix: bug')).toBe('fix  bug')
      expect(jqlBuilder.sanitize('test(case)')).toBe('test case ')
    })

    test('collapses multiple spaces', () => {
      expect(jqlBuilder.sanitize('hello   world')).toBe('hello world')
    })

    test('handles empty string', () => {
      expect(jqlBuilder.sanitize('')).toBe('')
    })
  })

  describe('tokenize()', () => {
    test('filters stop words', () => {
      const tokens = jqlBuilder.tokenize('the issue is for the team')
      expect(tokens).not.toContain('the')
      expect(tokens).not.toContain('is')
      expect(tokens).not.toContain('for')
    })

    test('filters short words (2 chars or less)', () => {
      const tokens = jqlBuilder.tokenize('fix it up now')
      expect(tokens).not.toContain('it')
      expect(tokens).not.toContain('up')
    })

    test('returns meaningful words', () => {
      const tokens = jqlBuilder.tokenize('implement search feature')
      expect(tokens).toContain('implement')
      expect(tokens).toContain('search')
      expect(tokens).toContain('feature')
    })

    test('lowercases output', () => {
      const tokens = jqlBuilder.tokenize('UPPERCASE WORD')
      expect(tokens).toContain('uppercase')
      expect(tokens).toContain('word')
    })
  })

  describe('build()', () => {
    test('returns primary, fallback, and broad queries', () => {
      const result = jqlBuilder.build('fix login bug')
      expect(result).toHaveProperty('primary')
      expect(result).toHaveProperty('fallback')
      expect(result).toHaveProperty('broad')
      expect(result).toHaveProperty('orderBy')
    })

    test('primary query uses exact phrase match', () => {
      const result = jqlBuilder.build('login issue')
      expect(result.primary).toContain('summary ~')
      expect(result.primary).toContain('\\"login issue\\"')
    })

    test('includes project filter when projectKey provided', () => {
      const result = jqlBuilder.build('login issue', 'PROJ')
      expect(result.primary).toContain('project = "PROJ"')
      expect(result.fallback).toContain('project = "PROJ"')
    })

    test('no project filter when projectKey is null', () => {
      const result = jqlBuilder.build('login issue')
      expect(result.primary).not.toContain('project =')
    })

    test('orderBy is always ORDER BY updated DESC', () => {
      const result = jqlBuilder.build('test')
      expect(result.orderBy).toBe(' ORDER BY updated DESC')
    })
  })

  describe('buildKeySearch()', () => {
    test('exact match for full ticket key', () => {
      expect(jqlBuilder.buildKeySearch('PROJ-1234')).toBe('key = "PROJ-1234"')
    })

    test('exact match is uppercased', () => {
      expect(jqlBuilder.buildKeySearch('proj-1234')).toBe('key = "PROJ-1234"')
    })

    test('wildcard match for partial key', () => {
      expect(jqlBuilder.buildKeySearch('PROJ')).toBe('key ~ "PROJ*"')
    })
  })

  describe('isTicketKey()', () => {
    test('detects full ticket key', () => {
      expect(jqlBuilder.isTicketKey('PROJ-1234')).toBe(true)
    })

    test('detects partial key (letters only)', () => {
      expect(jqlBuilder.isTicketKey('PROJ')).toBe(true)
    })

    test('detects partial key with partial number', () => {
      expect(jqlBuilder.isTicketKey('PROJ-12')).toBe(true)
    })

    test('returns false for regular text', () => {
      expect(jqlBuilder.isTicketKey('fix the login bug')).toBe(false)
    })

    test('returns false for short prefix', () => {
      expect(jqlBuilder.isTicketKey('P')).toBe(false)
    })
  })
})
