import { useState, useRef, useEffect } from 'react'
import { useNavigate, useParams, useLocation } from 'react-router-dom'
import api from '../lib/api'
import GamePreview from '../components/GamePreview'
import VoiceInput from '../components/VoiceInput'
import GameNameModal from '../components/GameNameModal'
import Celebration from '../components/Celebration'

export default function BuildPage({ session }) {
  const navigate = useNavigate()
  const { gameId: routeGameId } = useParams()
  const location = useLocation()

  const [gameId, setGameId] = useState(routeGameId || null)
  const [messages, setMessages] = useState([])
  const [input, setInput] = useState(location.state?.prompt || '')
  const [loading, setLoading] = useState(false)
  const [gameHtml, setGameHtml] = useState(null)
  const [showPreview, setShowPreview] = useState(false)
  const [showNameModal, setShowNameModal] = useState(false)
  const [showCelebration, setShowCelebration] = useState(false)
  const [publishedUrl, setPublishedUrl] = useState(null)
  const [gameName, setGameName] = useState('')
  const [copied, setCopied] = useState(false)

  const messagesEndRef = useRef(null)
  const inputRef = useRef(null)

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  useEffect(() => {
    if (location.state?.prompt && !routeGameId) {
      handleSend(location.state.prompt)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const handleSend = async (text) => {
    const msg = (text || input).trim()
    if (!msg || loading) return

    setInput('')
    setLoading(true)
    setMessages(prev => [...prev, { role: 'user', content: msg }])

    try {
      const { data } = await api.post('/conversation/message', { gameId, message: msg })
      setGameId(data.gameId)
      setMessages(prev => [...prev, { role: 'assistant', content: data.reply }])

      if (data.gameHtml) {
        setGameHtml(data.gameHtml)
        setShowPreview(true)
        setShowCelebration(true)
        setShowNameModal(true)
      }
    } catch {
      setMessages(prev => [...prev, {
        role: 'assistant',
        content: 'אוי, הייתה שגיאה. אפשר לנסות שוב? 😅'
      }])
    } finally {
      setLoading(false)
      inputRef.current?.focus()
    }
  }

  const handlePublish = async () => {
    if (!gameId) return
    try {
      const { data } = await api.post(`/games/${gameId}/publish`)
      setPublishedUrl(data.publishedUrl)
    } catch {
      alert('לא הצלחנו לפרסם את המשחק. נסה שוב.')
    }
  }

  const handleCopy = () => {
    navigator.clipboard.writeText(publishedUrl)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const handleNameSaved = (name) => {
    setGameName(name)
    setShowNameModal(false)
  }

  return (
    <div className="min-h-screen flex flex-col" style={{ background: '#F8F9FA' }}>

      {/* Header */}
      <header className="bg-white px-4 py-3 flex items-center gap-3"
        style={{ borderBottom: '1px solid #f0f0f0', boxShadow: '0 1px 8px rgba(0,0,0,0.04)' }}>
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 flex items-center justify-center rounded-xl transition-colors"
          style={{ background: 'rgba(0,0,0,0.04)', color: '#777' }}
          aria-label="חזרה"
        >
          ←
        </button>

        <div className="flex-1 min-w-0">
          <h1 className="font-black text-base truncate" style={{ color: '#2D2D2D' }}>
            {gameName || (routeGameId ? 'עריכת משחק ✏️' : 'משחק חדש 🎮')}
          </h1>
        </div>

        {gameHtml && (
          <button
            onClick={() => setShowPreview(v => !v)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-xl text-sm font-bold transition-all"
            style={{
              background: showPreview ? 'rgba(108,99,255,0.1)' : 'rgba(241,80,72,0.1)',
              color: showPreview ? '#6C63FF' : '#F15048'
            }}
          >
            {showPreview ? '💬 שיחה' : '🎮 משחק'}
          </button>
        )}
      </header>

      {/* Main area */}
      <div className="flex-1 flex flex-col overflow-hidden">

        {showPreview && gameHtml ? (
          /* Preview pane */
          <div className="flex-1 flex flex-col p-4 gap-3">
            <div className="flex-1 min-h-0 rounded-2xl overflow-hidden"
              style={{ boxShadow: '0 4px 20px rgba(0,0,0,0.08)' }}>
              <GamePreview gameId={gameId} html={gameHtml} onFixed={setGameHtml} />
            </div>

            {/* Publish row */}
            <div className="flex gap-2">
              {!publishedUrl ? (
                <button
                  onClick={handlePublish}
                  className="flex-1 touch-target font-black rounded-2xl flex items-center justify-center gap-2 active:scale-95 transition-transform"
                  style={{
                    background: 'linear-gradient(135deg, #F15048 0%, #6C63FF 100%)',
                    color: '#fff',
                    boxShadow: '0 6px 20px rgba(241,80,72,0.3)'
                  }}
                >
                  🔗 פרסם ושתף
                </button>
              ) : (
                <div className="flex-1 flex gap-2">
                  <div className="flex-1 flex items-center gap-2 px-3 py-2 rounded-xl"
                    style={{ background: '#fff', border: '2px solid #f0f0f0' }}>
                    <span className="text-xs">🔗</span>
                    <input
                      readOnly value={publishedUrl}
                      className="flex-1 text-xs font-mono bg-transparent outline-none truncate"
                      style={{ color: '#999' }}
                    />
                  </div>
                  <button
                    onClick={handleCopy}
                    className="px-4 rounded-xl text-sm font-bold transition-all active:scale-95"
                    style={{
                      background: copied ? 'rgba(46,204,113,0.1)' : 'rgba(108,99,255,0.1)',
                      color: copied ? '#2ECC71' : '#6C63FF'
                    }}
                  >
                    {copied ? '✓ הועתק' : 'העתק'}
                  </button>
                </div>
              )}
              <button
                onClick={() => setShowPreview(false)}
                className="touch-target px-4 rounded-2xl text-sm font-bold active:scale-95 transition-transform"
                style={{ background: '#fff', border: '2px solid #f0f0f0', color: '#777' }}
              >
                ✏️ ערוך
              </button>
            </div>
          </div>

        ) : (
          /* Chat pane */
          <div className="flex-1 overflow-y-auto px-4 py-4 flex flex-col gap-3">

            {messages.length === 0 && (
              <div className="text-center py-14 animate-slide-up">
                <div className="text-6xl mb-4 animate-float" style={{ display: 'inline-block' }}>🎮</div>
                <p className="font-black text-xl mb-2" style={{ color: '#2D2D2D' }}>
                  ספר לי על המשחק שאתה רוצה לבנות
                </p>
                <p className="text-sm font-semibold" style={{ color: '#bbb' }}>
                  אני אשאל אותך כמה שאלות ואז נבנה אותו ביחד! ✨
                </p>
              </div>
            )}

            {messages.map((msg, i) => (
              <div
                key={i}
                className="flex animate-slide-up"
                style={{
                  justifyContent: msg.role === 'user' ? 'flex-end' : 'flex-start',
                  animationDelay: `${i * 0.05}s`
                }}
              >
                {msg.role === 'assistant' && (
                  <div className="w-8 h-8 rounded-full flex items-center justify-center text-base flex-shrink-0 ml-2 self-end mb-1"
                    style={{ background: 'linear-gradient(135deg, #F15048, #6C63FF)' }}>
                    🤖
                  </div>
                )}
                <div className={msg.role === 'user' ? 'chat-bubble-user' : 'chat-bubble-ai'}
                  style={{ maxWidth: '78%' }}>
                  {msg.content}
                </div>
              </div>
            ))}

            {loading && (
              <div className="flex items-end gap-2">
                <div className="w-8 h-8 rounded-full flex items-center justify-center text-base flex-shrink-0"
                  style={{ background: 'linear-gradient(135deg, #F15048, #6C63FF)' }}>
                  🤖
                </div>
                <div className="chat-bubble-ai flex gap-1.5 items-center px-4 py-3">
                  {[0, 1, 2].map(i => (
                    <div
                      key={i}
                      className="w-2.5 h-2.5 rounded-full animate-bounce"
                      style={{
                        background: 'linear-gradient(135deg, #F15048, #6C63FF)',
                        animationDelay: `${i * 160}ms`
                      }}
                    />
                  ))}
                </div>
              </div>
            )}

            <div ref={messagesEndRef} />
          </div>
        )}

        {/* Input bar */}
        <div className="px-4 py-3 flex items-center gap-2"
          style={{
            background: '#fff',
            borderTop: '1px solid #f0f0f0',
            boxShadow: '0 -2px 12px rgba(0,0,0,0.04)'
          }}>
          <VoiceInput
            onTranscript={(text) => setInput(prev => prev + (prev ? ' ' : '') + text)}
            disabled={loading}
          />
          <input
            ref={inputRef}
            type="text"
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={e => e.key === 'Enter' && !e.shiftKey && handleSend()}
            placeholder={showPreview ? 'תאר שינוי למשחק...' : 'ספר לי על המשחק שלך...'}
            disabled={loading}
            className="flex-1 rounded-2xl px-4 py-3 text-sm font-semibold focus:outline-none transition-all"
            style={{
              background: '#f8f8f8',
              border: '2px solid transparent',
              color: '#2D2D2D',
            }}
            onFocus={e => e.target.style.borderColor = 'rgba(241,80,72,0.3)'}
            onBlur={e => e.target.style.borderColor = 'transparent'}
            dir="rtl"
          />
          <button
            onClick={() => handleSend()}
            disabled={loading || !input.trim()}
            className="w-12 h-12 flex items-center justify-center rounded-2xl transition-all active:scale-90 disabled:opacity-40"
            style={{
              background: input.trim() ? 'linear-gradient(135deg, #F15048, #6C63FF)' : '#f0f0f0',
              boxShadow: input.trim() ? '0 4px 14px rgba(241,80,72,0.35)' : 'none',
              color: '#fff'
            }}
            aria-label="שלח"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5">
              <path d="M3.478 2.405a.75.75 0 0 0-.926.94l2.432 7.905H13.5a.75.75 0 0 1 0 1.5H4.984l-2.432 7.905a.75.75 0 0 0 .926.94 60.519 60.519 0 0 0 18.445-8.986.75.75 0 0 0 0-1.218A60.517 60.517 0 0 0 3.478 2.405z" />
            </svg>
          </button>
        </div>
      </div>

      {showNameModal && gameId && (
        <GameNameModal gameId={gameId} onSave={handleNameSaved} onSkip={() => setShowNameModal(false)} />
      )}

      {showCelebration && (
        <Celebration onDone={() => setShowCelebration(false)} />
      )}
    </div>
  )
}
