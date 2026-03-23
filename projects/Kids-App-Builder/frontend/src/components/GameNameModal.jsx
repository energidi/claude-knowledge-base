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
    <div className="fixed inset-0 bg-black/50 flex items-end sm:items-center justify-center z-50 px-4 pb-4 sm:pb-0">
      <div className="bg-white rounded-3xl p-6 w-full max-w-sm shadow-xl">
        <p className="text-xl font-black text-text-primary mb-2 text-center">🎉 המשחק מוכן!</p>
        <p className="text-text-secondary text-sm text-center mb-5">תן שם למשחק שלך:</p>

        {loadingSuggestion ? (
          <div className="flex justify-center py-4">
            <div className="w-6 h-6 rounded-full border-3 border-coral border-t-transparent animate-spin" />
          </div>
        ) : (
          <input
            type="text"
            value={name}
            onChange={e => setName(e.target.value)}
            placeholder={suggested || 'שם המשחק...'}
            className="w-full bg-gray-50 border-2 border-gray-100 focus:border-coral rounded-2xl px-4 py-3 font-bold text-text-primary text-center focus:outline-none mb-4"
            dir="rtl"
            maxLength={40}
          />
        )}

        <div className="flex gap-3">
          <button
            onClick={onSkip}
            className="flex-1 touch-target py-3 rounded-2xl border-2 border-gray-100 text-text-secondary font-bold"
          >
            אחר כך
          </button>
          <button
            onClick={handleSave}
            disabled={saving || loadingSuggestion}
            className="flex-1 touch-target py-3 rounded-2xl bg-coral text-white font-black disabled:opacity-50"
          >
            שמור
          </button>
        </div>
      </div>
    </div>
  )
}
