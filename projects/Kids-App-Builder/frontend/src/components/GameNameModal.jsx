import { useState, useEffect } from 'react'
import api from '../lib/api'

export default function GameNameModal({ gameId, onSave, onSkip }) {
  const [name, setName] = useState('')
  const [suggested, setSuggested] = useState('')
  const [loadingSuggestion, setLoadingSuggestion] = useState(true)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    api.post('/conversation/suggest-name', { gameId })
      .then(({ data }) => {
        setSuggested(data.name)
        setName(data.name)
      })
      .catch(() => {})
      .finally(() => setLoadingSuggestion(false))
  }, [gameId])

  const handleSave = async () => {
    const finalName = name.trim() || suggested || 'המשחק שלי'
    setSaving(true)
    try {
      await api.patch(`/games/${gameId}/name`, { name: finalName })
      onSave(finalName)
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 flex items-end sm:items-center justify-center z-50 px-4 pb-4 sm:pb-0"
      style={{ background: 'rgba(0,0,0,0.5)', backdropFilter: 'blur(4px)' }}>
      <div
        className="bg-white rounded-3xl p-6 w-full max-w-sm animate-slide-up"
        style={{ boxShadow: '0 24px 60px rgba(0,0,0,0.2)' }}
      >
        <div className="text-center mb-5">
          <div className="text-4xl mb-2">✨</div>
          <p className="font-black text-xl" style={{ color: '#2D2D2D' }}>תן שם למשחק!</p>
          <p className="text-sm font-semibold mt-1" style={{ color: '#bbb' }}>
            {loadingSuggestion ? 'מחשב שם...' : 'אנחנו הצענו שם - אבל אתה יכול לשנות'}
          </p>
        </div>

        {loadingSuggestion ? (
          <div className="skeleton h-14 w-full mb-4" />
        ) : (
          <input
            type="text"
            value={name}
            onChange={e => setName(e.target.value)}
            placeholder={suggested || 'שם המשחק...'}
            className="w-full rounded-2xl px-4 py-3 font-black text-lg text-center focus:outline-none mb-4 transition-all"
            style={{
              background: '#f8f8f8',
              border: '2px solid #f0f0f0',
              color: '#2D2D2D'
            }}
            onFocus={e => e.target.style.borderColor = 'rgba(241,80,72,0.4)'}
            onBlur={e => e.target.style.borderColor = '#f0f0f0'}
            dir="rtl"
            maxLength={40}
            autoFocus
          />
        )}

        <div className="flex gap-3">
          <button
            onClick={onSkip}
            className="flex-1 touch-target py-3 rounded-2xl font-bold text-sm transition-colors"
            style={{ border: '2px solid #f0f0f0', color: '#bbb', background: '#fff' }}
          >
            אחר כך
          </button>
          <button
            onClick={handleSave}
            disabled={saving || loadingSuggestion}
            className="flex-1 touch-target py-3 rounded-2xl font-black text-white active:scale-95 transition-all disabled:opacity-50"
            style={{
              background: 'linear-gradient(135deg, #F15048, #6C63FF)',
              boxShadow: '0 6px 18px rgba(241,80,72,0.3)'
            }}
          >
            {saving ? '...' : 'שמור 🎮'}
          </button>
        </div>
      </div>
    </div>
  )
}
