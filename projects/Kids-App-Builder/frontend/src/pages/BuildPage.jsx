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

  const messagesEndRef = useRef(null)
  const inputRef = useRef(null)

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  // Auto-send if arriving from inspiration chip
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
      const { data } = await api.post('/conversation/message', {
        gameId,
        message: msg
      })

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
        content: 'אוי, הייתה שגיאה. אפשר לנסות שוב?'
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

  const handleNameSaved = (name) => {
    setGameName(name)
    setShowNameModal(false)
  }

  return (
    <div className="min-h-screen bg-bg flex flex-col">
      {/* Header */}
      <header className="bg-white shadow-sm px-5 py-4 flex items-center gap-3">
        <button
          onClick={() => navigate('/')}
          className="text-text-secondary font-bold text-lg leading-none"
          aria-label="חזרה"
        >
          ←
        </button>
        <h1 className="text-lg font-black text-coral flex-1">
          {gameName || (routeGameId ? 'עריכת משחק' : 'משחק חדש')}
        </h1>
        {gameHtml && (
          <button
            onClick={() => setShowPreview(v => !v)}
            className="text-sm font-bold text-purple-brand"
          >
            {showPreview ? 'הצג שיחה' : 'הצג משחק'}
          </button>
        )}
      </header>

      {/* Main area */}
      <div className="flex-1 flex flex-col overflow-hidden">
        {showPreview && gameHtml ? (
          /* Preview pane */
          <div className="flex-1 flex flex-col p-4 gap-4">
            <div className="flex-1 min-h-0">
              <GamePreview
                gameId={gameId}
                html={gameHtml}
                onFixed={setGameHtml}
              />
            </div>

            {/* Publish / share row */}
            <div className="flex gap-3">
              {!publishedUrl ? (
                <button
                  onClick={handlePublish}
                  className="flex-1 touch-target bg-coral text-white font-black rounded-2xl py-3 active:scale-95 transition-transform"
                >
                  פרסם ושתף
                </button>
              ) : (
                <div className="flex-1 flex gap-2">
                  <input
                    readOnly
                    value={publishedUrl}
                    className="flex-1 bg-white border-2 border-gray-100 rounded-xl px-3 py-2 text-sm font-mono text-text-secondary"
                  />
                  <button
                    onClick={() => navigator.clipboard.writeText(publishedUrl)}
                    className="px-4 bg-success text-white font-bold rounded-xl text-sm"
                  >
                    העתק
                  </button>
                </div>
              )}
              <button
                onClick={() => setShowPreview(false)}
                className="touch-target px-4 bg-white border-2 border-gray-100 text-text-secondary font-bold rounded-2xl text-sm"
              >
                ערוך עוד
              </button>
            </div>
          </div>
        ) : (
          /* Chat pane */
          <div className="flex-1 overflow-y-auto px-5 py-4 flex flex-col gap-3">
            {messages.length === 0 && (
              <div className="text-center py-12">
                <p className="text-4xl mb-4">🎮</p>
                <p className="font-bold text-text-primary text-lg">ספר לי על המשחק שאתה רוצה לבנות</p>
                <p className="text-text-secondary mt-2">אני אשאל אותך כמה שאלות ואז נבנה אותו ביחד!</p>
              </div>
            )}

            {messages.map((msg, i) => (
              <div
                key={i}
                className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
              >
                <div className={`
                  max-w-[80%] px-4 py-3 rounded-2xl font-semibold text-sm leading-relaxed
                  ${msg.role === 'user'
                    ? 'bg-coral text-white rounded-tl-sm'
                    : 'bg-white text-text-primary shadow-sm rounded-tr-sm'
                  }
                `}>
                  {msg.content}
                </div>
              </div>
            ))}

            {loading && (
              <div className="flex justify-start">
                <div className="bg-white shadow-sm rounded-2xl rounded-tr-sm px-4 py-3 flex gap-1">
                  {[0, 1, 2].map(i => (
                    <div
                      key={i}
                      className="w-2 h-2 bg-gray-300 rounded-full animate-bounce"
                      style={{ animationDelay: `${i * 150}ms` }}
                    />
                  ))}
                </div>
              </div>
            )}

            <div ref={messagesEndRef} />
          </div>
        )}

        {/* Input bar */}
        <div className="bg-white border-t border-gray-100 px-4 py-3 flex items-center gap-2">
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
            placeholder={showPreview ? 'תאר שינוי...' : 'תאר את המשחק שלך...'}
            disabled={loading}
            className="flex-1 bg-gray-50 rounded-xl px-4 py-3 text-sm font-semibold text-text-primary placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-coral/30"
            dir="rtl"
          />
          <button
            onClick={() => handleSend()}
            disabled={loading || !input.trim()}
            className="touch-target w-12 h-12 flex items-center justify-center bg-coral text-white rounded-xl disabled:opacity-40 active:scale-95 transition-transform"
            aria-label="שלח"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5">
              <path d="M3.478 2.405a.75.75 0 0 0-.926.94l2.432 7.905H13.5a.75.75 0 0 1 0 1.5H4.984l-2.432 7.905a.75.75 0 0 0 .926.94 60.519 60.519 0 0 0 18.445-8.986.75.75 0 0 0 0-1.218A60.517 60.517 0 0 0 3.478 2.405z" />
            </svg>
          </button>
        </div>
      </div>

      {/* Modals */}
      {showNameModal && gameId && (
        <GameNameModal
          gameId={gameId}
          onSave={handleNameSaved}
          onSkip={() => setShowNameModal(false)}
        />
      )}

      {showCelebration && (
        <Celebration onDone={() => setShowCelebration(false)} />
      )}
    </div>
  )
}
