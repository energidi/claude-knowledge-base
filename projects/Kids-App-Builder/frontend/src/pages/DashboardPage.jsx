import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useProfile } from '../hooks/useProfile'
import api from '../lib/api'

const INSPIRATION_CHIPS = [
  { label: 'כדור מנפץ לבנים', emoji: '🧱' },
  { label: 'מטוס יורה על אסטרואידים', emoji: '🚀' },
  { label: 'נחש אוכל תפוחים וגדל', emoji: '🐍' },
  { label: 'דמות קופצת על פלטפורמות', emoji: '🦘' },
  { label: 'מכונית נמנעת ממכשולים', emoji: '🚗' },
  { label: 'חידון על חיות', emoji: '🦁' },
]

const GAME_COLORS = [
  { bg: 'rgba(241,80,72,0.08)', border: 'rgba(241,80,72,0.2)', dot: '#F15048' },
  { bg: 'rgba(108,99,255,0.08)', border: 'rgba(108,99,255,0.2)', dot: '#6C63FF' },
  { bg: 'rgba(46,204,113,0.08)', border: 'rgba(46,204,113,0.2)', dot: '#2ECC71' },
  { bg: 'rgba(255,184,0,0.08)', border: 'rgba(255,184,0,0.2)', dot: '#FFB800' },
  { bg: 'rgba(0,188,212,0.08)', border: 'rgba(0,188,212,0.2)', dot: '#00BCD4' },
]

const GAME_EMOJIS = ['🎮', '🕹️', '⚡', '🔥', '💎', '🌟', '🎯', '🏆']

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

  const timeGreeting = () => {
    const h = new Date().getHours()
    if (h < 12) return 'בוקר טוב'
    if (h < 17) return 'צהריים טובים'
    return 'ערב טוב'
  }

  const firstName = profile?.display_name?.split(' ')[0] || ''

  return (
    <div className="min-h-screen pb-24" style={{ background: 'linear-gradient(180deg, #fff5f5 0%, #F8F9FA 180px)' }}>

      {/* Header */}
      <header className="px-5 pt-5 pb-4 flex items-center justify-between">
        <h1 className="text-2xl font-black gradient-text">PlayBuild</h1>
        <div className="flex items-center gap-3">
          {profile?.avatar_url
            ? <img src={profile.avatar_url} alt="" className="w-10 h-10 rounded-full"
                style={{ border: '2px solid rgba(241,80,72,0.3)', boxShadow: '0 2px 8px rgba(241,80,72,0.15)' }} />
            : <div className="w-10 h-10 rounded-full gradient-brand flex items-center justify-center text-white font-black text-lg">
                {firstName[0] || '?'}
              </div>
          }
          <button onClick={handleSignOut}
            className="text-sm font-bold px-3 py-1.5 rounded-xl transition-colors"
            style={{ color: '#999', background: 'rgba(0,0,0,0.04)' }}>
            יציאה
          </button>
        </div>
      </header>

      <main className="px-5 max-w-2xl mx-auto">

        {/* Greeting */}
        <div className="mb-6 animate-slide-up">
          <p className="text-3xl font-black" style={{ color: '#2D2D2D', lineHeight: 1.2 }}>
            {timeGreeting()}
            {firstName && <span className="gradient-text"> {firstName}! </span>}
            👋
          </p>
          <p className="text-base font-semibold mt-1" style={{ color: '#999' }}>
            מה תרצה לבנות היום?
          </p>
        </div>

        {/* New game CTA */}
        <button
          onClick={() => navigate('/build')}
          className="w-full rounded-3xl mb-7 flex items-center justify-between px-6 active:scale-95 transition-transform duration-150"
          style={{
            height: '72px',
            background: 'linear-gradient(135deg, #F15048 0%, #6C63FF 100%)',
            boxShadow: '0 8px 28px rgba(241,80,72,0.35)',
          }}
        >
          <span className="text-white font-black text-lg">בנה משחק חדש</span>
          <span className="text-3xl">🎮</span>
        </button>

        {/* Inspiration chips */}
        <div className="mb-8">
          <p className="text-sm font-black mb-3 uppercase tracking-wide" style={{ color: '#bbb' }}>
            רעיונות לדוגמה
          </p>
          <div className="flex flex-wrap gap-2">
            {INSPIRATION_CHIPS.map((chip) => (
              <button
                key={chip.label}
                onClick={() => navigate('/build', { state: { prompt: chip.label } })}
                className="flex items-center gap-2 px-4 py-2.5 rounded-2xl text-sm font-bold transition-all duration-150 active:scale-95"
                style={{
                  background: '#fff',
                  border: '2px solid #f0f0f0',
                  color: '#2D2D2D',
                  boxShadow: '0 2px 8px rgba(0,0,0,0.04)'
                }}
                onMouseEnter={e => {
                  e.currentTarget.style.borderColor = '#F15048'
                  e.currentTarget.style.color = '#F15048'
                }}
                onMouseLeave={e => {
                  e.currentTarget.style.borderColor = '#f0f0f0'
                  e.currentTarget.style.color = '#2D2D2D'
                }}
              >
                <span>{chip.emoji}</span>
                <span>{chip.label}</span>
              </button>
            ))}
          </div>
        </div>

        {/* Games list */}
        <div>
          <p className="text-sm font-black mb-3 uppercase tracking-wide" style={{ color: '#bbb' }}>
            המשחקים שלי
          </p>

          {loadingGames ? (
            <div className="flex flex-col gap-3">
              {[1, 2].map(i => (
                <div key={i} className="skeleton h-20 w-full" />
              ))}
            </div>
          ) : games.length === 0 ? (
            <div className="text-center py-12 rounded-3xl"
              style={{ background: '#fff', border: '2px dashed #f0f0f0' }}>
              <p className="text-4xl mb-3">🎯</p>
              <p className="font-bold text-base" style={{ color: '#2D2D2D' }}>
                עוד לא בנית משחקים
              </p>
              <p className="text-sm font-semibold mt-1" style={{ color: '#bbb' }}>
                לחץ על "בנה משחק חדש" כדי להתחיל!
              </p>
            </div>
          ) : (
            <div className="flex flex-col gap-3">
              {games.map((game, i) => (
                <GameCard
                  key={game.id}
                  game={game}
                  index={i}
                  onEdit={() => navigate(`/build/${game.id}`)}
                />
              ))}
            </div>
          )}
        </div>
      </main>
    </div>
  )
}

function GameCard({ game, index, onEdit }) {
  const color = GAME_COLORS[index % GAME_COLORS.length]
  const emoji = GAME_EMOJIS[index % GAME_EMOJIS.length]

  return (
    <div
      className="rounded-2xl p-4 flex items-center gap-4 transition-all duration-150 active:scale-98"
      style={{
        background: '#fff',
        border: `2px solid ${color.border}`,
        boxShadow: '0 2px 12px rgba(0,0,0,0.05)'
      }}
    >
      {/* Icon */}
      <div className="w-12 h-12 rounded-xl flex items-center justify-center text-2xl flex-shrink-0"
        style={{ background: color.bg }}>
        {emoji}
      </div>

      {/* Info */}
      <div className="flex-1 min-w-0">
        <p className="font-black text-base truncate" style={{ color: '#2D2D2D' }}>{game.name}</p>
        <p className="text-xs font-semibold mt-0.5" style={{ color: '#bbb' }}>
          {new Date(game.updated_at).toLocaleDateString('he-IL', { day: 'numeric', month: 'long' })}
        </p>
      </div>

      {/* Actions */}
      <div className="flex gap-2 flex-shrink-0">
        {game.published_url && (
          <a
            href={game.published_url}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm font-bold transition-colors"
            style={{ background: 'rgba(46,204,113,0.1)', color: '#2ECC71' }}
          >
            <span>▶</span>
            <span>שחק</span>
          </a>
        )}
        <button
          onClick={onEdit}
          className="flex items-center gap-1.5 px-3 py-2 rounded-xl text-sm font-bold transition-colors"
          style={{ background: color.bg, color: color.dot }}
        >
          <span>✏️</span>
          <span>ערוך</span>
        </button>
      </div>
    </div>
  )
}
