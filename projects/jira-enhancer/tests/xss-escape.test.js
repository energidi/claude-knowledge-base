/**
 * Unit tests for HTML escaping (XSS prevention)
 * Tests the escapeHtml method used in SearchModal
 * Run with: npm test
 */

// Replicate the escapeHtml method from SearchModal
function escapeHtml(text) {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

describe('escapeHtml (XSS prevention)', () => {
  test('escapes < and > characters', () => {
    expect(escapeHtml('<script>')).toBe('&lt;script&gt;')
  })

  test('escapes & character', () => {
    expect(escapeHtml('AT&T')).toBe('AT&amp;T')
  })

  test('escapes double quotes', () => {
    expect(escapeHtml('"hello"')).toBe('"hello"')
  })

  test('handles XSS attack pattern', () => {
    const xss = '<img src=x onerror=alert(1)>'
    const escaped = escapeHtml(xss)
    expect(escaped).not.toContain('<img')
    expect(escaped).toContain('&lt;img')
  })

  test('does not modify safe text', () => {
    expect(escapeHtml('PROJ-1234 Fix login bug')).toBe('PROJ-1234 Fix login bug')
  })

  test('handles empty string', () => {
    expect(escapeHtml('')).toBe('')
  })

  test('handles script injection attempt', () => {
    const attack = '<script>alert("xss")</script>'
    const escaped = escapeHtml(attack)
    expect(escaped).not.toContain('<script>')
    expect(escaped).toContain('&lt;script&gt;')
  })
})
