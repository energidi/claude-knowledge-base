import { useEffect, useRef, useState, useCallback } from 'react'
import api from '../lib/api'

const MAX_RETRIES = 3

/**
 * Renders a game HTML string in a sandboxed iframe.
 * Catches JS errors and retries self-correction via the backend (max 3 times).
 */
export default function GamePreview({ gameId, html, onFixed }) {
  const iframeRef = useRef(null)
  const [status, setStatus] = useState('idle') // idle | loading | running | error | fixing
  const [retryCount, setRetryCount] = useState(0)
  const currentHtmlRef = useRef(html)

  const loadHtml = useCallback((htmlContent) => {
    if (!iframeRef.current) return
    setStatus('loading')
    const blob = new Blob([htmlContent], { type: 'text/html' })
    const url = URL.createObjectURL(blob)
    iframeRef.current.src = url
    return () => URL.revokeObjectURL(url)
  }, [])

  // Load initial HTML
  useEffect(() => {
    if (!html) return
    currentHtmlRef.current = html
    setRetryCount(0)
    setStatus('idle')
    const cleanup = loadHtml(html)
    return cleanup
  }, [html, loadHtml])

  // Listen for errors from inside the iframe
  useEffect(() => {
    const handleMessage = async (event) => {
      if (event.data?.type !== 'GAME_ERROR') return

      const errorMessage = event.data.error
      const attempt = retryCount + 1

      if (attempt > MAX_RETRIES) {
        setStatus('error')
        return
      }

      setStatus('fixing')
      setRetryCount(attempt)

      try {
        const { data } = await api.post('/conversation/fix', {
          gameId,
          html: currentHtmlRef.current,
          error: errorMessage
        })
        if (data.html) {
          currentHtmlRef.current = data.html
          onFixed?.(data.html)
          loadHtml(data.html)
        } else {
          setStatus('error')
        }
      } catch {
        setStatus('error')
      }
    }

    window.addEventListener('message', handleMessage)
    return () => window.removeEventListener('message', handleMessage)
  }, [retryCount, gameId, loadHtml, onFixed])

  // Error reporter injected into the iframe via srcdoc wrapper
  const wrapWithErrorReporter = (rawHtml) => {
    const errorScript = `
<script>
window.onerror = function(msg, src, line, col, err) {
  window.parent.postMessage({ type: 'GAME_ERROR', error: msg + ' (line ' + line + ')' }, '*');
  return true;
};
window.addEventListener('unhandledrejection', function(e) {
  window.parent.postMessage({ type: 'GAME_ERROR', error: e.reason?.message || 'שגיאה לא ידועה' }, '*');
});
window.addEventListener('load', function() {
  window.parent.postMessage({ type: 'GAME_LOADED' }, '*');
});
<\/script>`
    return rawHtml.replace('</head>', errorScript + '</head>')
  }

  useEffect(() => {
    if (!html) return
    const wrapped = wrapWithErrorReporter(html)
    currentHtmlRef.current = html

    const handleLoad = (event) => {
      if (event.data?.type === 'GAME_LOADED') setStatus('running')
    }
    window.addEventListener('message', handleLoad)

    const cleanup = loadHtml(wrapped)
    return () => {
      window.removeEventListener('message', handleLoad)
      cleanup?.()
    }
  }, [html]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!html) return null

  return (
    <div className="relative w-full h-full rounded-2xl overflow-hidden bg-gray-900">
      <iframe
        ref={iframeRef}
        title="משחק"
        sandbox="allow-scripts"
        className="w-full h-full border-0"
        allow=""
      />

      {status === 'fixing' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/60 text-white gap-3">
          <div className="w-10 h-10 rounded-full border-4 border-coral border-t-transparent animate-spin" />
          <p className="font-bold text-lg">מתקן את המשחק... ({retryCount}/{MAX_RETRIES})</p>
        </div>
      )}

      {status === 'error' && (
        <div className="absolute inset-0 flex flex-col items-center justify-center bg-black/70 text-white gap-4 px-6 text-center">
          <span className="text-4xl">😅</span>
          <p className="font-bold text-xl">אוי, משהו השתבש במשחק</p>
          <p className="text-gray-300">נסה לתאר את המשחק שוב עם קצת יותר פרטים</p>
        </div>
      )}
    </div>
  )
}
