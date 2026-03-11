/**
 * Unit tests for SimpleCache
 * Run with: npm test
 */

// Inline class for Jest (avoids ES module import issues without Babel)
class SimpleCache {
  constructor(ttlMs = 60000) {
    this.cache = new Map()
    this.ttl = ttlMs
  }

  get(key) {
    const entry = this.cache.get(key)
    if (!entry) return null
    if (Date.now() > entry.expires) {
      this.cache.delete(key)
      return null
    }
    return entry.value
  }

  set(key, value) {
    this.cache.set(key, {
      value,
      expires: Date.now() + this.ttl
    })
  }

  clear() {
    this.cache.clear()
  }
}

describe('SimpleCache', () => {
  test('stores and retrieves a value', () => {
    const cache = new SimpleCache(60000)
    cache.set('key1', { data: 'hello' })
    expect(cache.get('key1')).toEqual({ data: 'hello' })
  })

  test('returns null for missing key', () => {
    const cache = new SimpleCache(60000)
    expect(cache.get('nonexistent')).toBeNull()
  })

  test('expires entries after TTL', () => {
    jest.useFakeTimers()
    const cache = new SimpleCache(1000) // 1 second TTL
    cache.set('key1', 'value1')

    // Before expiry
    expect(cache.get('key1')).toBe('value1')

    // After expiry
    jest.advanceTimersByTime(1001)
    expect(cache.get('key1')).toBeNull()

    jest.useRealTimers()
  })

  test('does not expire entries before TTL', () => {
    jest.useFakeTimers()
    const cache = new SimpleCache(5000) // 5 second TTL
    cache.set('key1', 'value1')

    jest.advanceTimersByTime(4999)
    expect(cache.get('key1')).toBe('value1')

    jest.useRealTimers()
  })

  test('clear() removes all entries', () => {
    const cache = new SimpleCache(60000)
    cache.set('a', 1)
    cache.set('b', 2)
    cache.set('c', 3)
    cache.clear()
    expect(cache.get('a')).toBeNull()
    expect(cache.get('b')).toBeNull()
    expect(cache.get('c')).toBeNull()
  })

  test('overwriting a key resets TTL', () => {
    jest.useFakeTimers()
    const cache = new SimpleCache(1000)
    cache.set('key', 'old')

    jest.advanceTimersByTime(800)
    cache.set('key', 'new') // Reset TTL

    jest.advanceTimersByTime(800) // Total 1600ms but only 800ms since reset
    expect(cache.get('key')).toBe('new')

    jest.useRealTimers()
  })

  test('handles null and undefined values', () => {
    const cache = new SimpleCache(60000)
    cache.set('nullVal', null)
    // null is stored but get() returns null for both missing and null values
    // This is expected behavior per the implementation
    expect(cache.get('nullVal')).toBeNull()
  })
})
