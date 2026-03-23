/**
 * PlayBuild Game Worker
 * Serves static game HTML files from Cloudflare R2.
 * URL pattern: https://playbuild.workers.dev/<game-id>
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    const gameId = url.pathname.replace(/^\//, '').split('/')[0]

    if (!gameId) {
      return new Response('PlayBuild Game Server', { status: 200 })
    }

    // Validate UUID format to prevent path traversal
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    if (!uuidPattern.test(gameId)) {
      return new Response('לא נמצא', { status: 404 })
    }

    const object = await env.GAMES_BUCKET.get(`${gameId}.html`)

    if (!object) {
      return new Response('המשחק לא נמצא', { status: 404 })
    }

    const html = await object.text()

    return new Response(html, {
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'public, max-age=3600',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'SAMEORIGIN',
        'Content-Security-Policy': "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src * data:; media-src *; connect-src 'none'"
      }
    })
  }
}
