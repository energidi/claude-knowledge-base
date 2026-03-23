import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useProfile } from '../hooks/useProfile'
import api from '../lib/api'

const INSPIRATION_CHIPS = [
  'משחק שבו כדור קופץ ומנפץ לבנים',
  'מטוס שיורה על אסטרואידים',
  'נחש שאוכל תפוחים וגדל',
  'דמות שקופצת על פלטפורמות',
  'מכונית שנמנעת ממכשולים',
  'חידון שאלות על חיות'
]

export default function DashboardPage({ session }) {
  const navigate = useNavigate()
  const { profile } = useProfile(session.user.id)
  const [games, setGames] = useState([])
  const [loadingGames, setLoadingGames] = useState(true)

  useEffect(() => {
    api.get('/games').then(({ data }) => {
      setGames(data.games || [])
      setLoadingGames(false)
    })
  }, [])

  const handleSignOut = () => supabase.auth.signOut()

  const greeting = profile
    ? `שלום ${profile.display_name}, מה תרצה לבנות היום?`
    : 'שלום! מה תרצה לבנות היום?'

  return (
    <div className="min-h-screen bg-bg pb-24">
      {/* Header */}
      <header className="bg-white shadow-sm px-5 py-4 flex items-center justify-between">
        <h1 className="text-2xl font-black text-coral">PlayBuild</h1>
        <div className="flex items-center gap-3">
          {profile?.avatar_url && (
            <img src={profile.avatar_url} alt="" className="w-9 h-9 rounded-full" />
          )}
          <button onClick={handleSignOut} className="text-sm text-text-secondary font-semibold">
            יציאה
          </button>
        </div>
      </header>

      <main className="px-5 pt-6 max-w-2xl mx-auto">
        {/* Greeting */}
        <p className="text-xl font-bold text-text-primary mb-6">{greeting}</p>

        {/* New game button */}
        <button
          onClick={() => navigate('/build')}
          className="w-full touch-target bg-coral text-white font-black text-lg rounded-2xl py-4 mb-8 shadow-lg shadow-coral/30 active:scale-95 transition-transform"
        >
          + בנה משחק חדש
        </button>

        {/* Inspiration chips */}
        <div className="mb-8">
          <p className="text-sm font-bold text-text-secondary mb-3">רעיונות לדוגמה:</p>
          <div className="flex flex-wrap gap-2">
            {INSPIRATION_CHIPS.map((chip) => (
              <button
                key={chip}
                onClick={() => navigate('/build', { state: { prompt: chip } })}
                className="px-4 py-2 bg-white border-2 border-gray-100 rounded-full text-sm font-semibold text-text-primary hover:border-coral hover:text-coral transition-colors active:scale-95"
              >
                {chip}
              </button>
            ))}
          </div>
        </div>

        {/* Games list */}
        <div>
          <p className="text-sm font-bold text-text-secondary mb-3">המשחקים שלי:</p>
          {loadingGames ? (
            <div className="flex justify-center py-10">
              <div className="w-8 h-8 rounded-full border-4 border-coral border-t-transparent animate-spin" />
            </div>
          ) : games.length === 0 ? (
            <p className="text-center text-text-secondary py-10 font-semibold">
              עוד לא בנית משחקים - בוא נתחיל!
            </p>
          ) : (
            <div className="grid grid-cols-1 gap-4">
              {games.map((game) => (
                <GameCard key={game.id} game={game} onEdit={() => navigate(`/build/${game.id}`)} />
              ))}
            </div>
          )}
        </div>
      </main>
    </div>
  )
}

function GameCard({ game, onEdit }) {
  return (
    <div className="bg-white rounded-2xl p-4 shadow-sm flex items-center justify-between gap-4">
      <div className="min-w-0">
        <p className="font-bold text-text-primary truncate">{game.name}</p>
        <p className="text-sm text-text-secondary">
          {new Date(game.updated_at).toLocaleDateString('he-IL')}
        </p>
      </div>
      <div className="flex gap-2 shrink-0">
        {game.published_url && (
          <a
            href={game.published_url}
            target="_blank"
            rel="noopener noreferrer"
            className="touch-target flex items-center px-3 py-2 bg-success/10 text-success rounded-xl text-sm font-bold"
          >
            שחק
          </a>
        )}
        <button
          onClick={onEdit}
          className="touch-target flex items-center px-3 py-2 bg-purple-brand/10 text-purple-brand rounded-xl text-sm font-bold"
        >
          ערוך
        </button>
      </div>
    </div>
  )
}
