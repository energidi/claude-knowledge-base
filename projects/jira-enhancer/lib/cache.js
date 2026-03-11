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

export default SimpleCache
