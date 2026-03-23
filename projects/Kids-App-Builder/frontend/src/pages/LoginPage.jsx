import { supabase } from '../lib/supabase'

const FLOATING_EMOJIS = [
  { emoji: '🎮', style: { top: '8%', right: '10%', animationDelay: '0s', fontSize: '2.5rem' } },
  { emoji: '🚀', style: { top: '20%', left: '8%', animationDelay: '0.8s', fontSize: '2rem' } },
  { emoji: '⭐', style: { top: '55%', right: '6%', animationDelay: '1.2s', fontSize: '1.8rem' } },
  { emoji: '🏆', style: { top: '70%', left: '10%', animationDelay: '0.4s', fontSize: '2rem' } },
  { emoji: '🎯', style: { top: '38%', right: '14%', animationDelay: '1.6s', fontSize: '1.6rem' } },
  { emoji: '💥', style: { top: '82%', right: '20%', animationDelay: '0.6s', fontSize: '1.5rem' } },
  { emoji: '🌟', style: { top: '15%', right: '35%', animationDelay: '1s', fontSize: '1.4rem' } },
]

export default function LoginPage() {
  const handleGoogleLogin = async () => {
    await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin }
    })
  }

  return (
    <div className="min-h-screen flex flex-col items-center justify-center px-6 relative overflow-hidden"
      style={{ background: 'linear-gradient(160deg, #fff5f5 0%, #f8f5ff 50%, #f0f8ff 100%)' }}
    >
      {/* Floating background emojis */}
      {FLOATING_EMOJIS.map((item, i) => (
        <span
          key={i}
          className={i % 2 === 0 ? 'animate-float' : 'animate-float2'}
          style={{
            position: 'absolute',
            opacity: 0.35,
            pointerEvents: 'none',
            userSelect: 'none',
            ...item.style
          }}
        >
          {item.emoji}
        </span>
      ))}

      {/* Background blobs */}
      <div style={{
        position: 'absolute', top: '-80px', right: '-80px',
        width: '300px', height: '300px', borderRadius: '50%',
        background: 'radial-gradient(circle, rgba(241,80,72,0.12) 0%, transparent 70%)',
        pointerEvents: 'none'
      }} />
      <div style={{
        position: 'absolute', bottom: '-60px', left: '-60px',
        width: '250px', height: '250px', borderRadius: '50%',
        background: 'radial-gradient(circle, rgba(108,99,255,0.12) 0%, transparent 70%)',
        pointerEvents: 'none'
      }} />

      {/* Logo + tagline */}
      <div className="mb-10 text-center animate-slide-up" style={{ animationDelay: '0.1s' }}>
        <div className="text-6xl mb-4" style={{ filter: 'drop-shadow(0 4px 12px rgba(241,80,72,0.3))' }}>
          🎮
        </div>
        <h1 className="text-6xl font-black mb-3 gradient-text" style={{ letterSpacing: '-1px' }}>
          PlayBuild
        </h1>
        <p className="text-lg font-bold" style={{ color: '#777' }}>
          בנה משחקים עם בינה מלאכותית ✨
        </p>
      </div>

      {/* Feature pills */}
      <div className="flex gap-2 flex-wrap justify-center mb-8 animate-slide-up" style={{ animationDelay: '0.2s' }}>
        {['🗣️ דבר עם ה-AI', '⚡ קוד נוצר מיידית', '🔗 שתף עם חברים'].map(f => (
          <span key={f} className="px-4 py-2 rounded-full text-sm font-bold"
            style={{ background: 'rgba(241,80,72,0.08)', color: '#F15048' }}>
            {f}
          </span>
        ))}
      </div>

      {/* Card */}
      <div className="bg-white rounded-3xl p-8 w-full max-w-sm text-center animate-pop-in"
        style={{
          animationDelay: '0.3s',
          boxShadow: '0 20px 60px rgba(0,0,0,0.1), 0 4px 16px rgba(241,80,72,0.08)'
        }}
      >
        <p className="font-black text-xl mb-2" style={{ color: '#2D2D2D' }}>מוכן להתחיל?</p>
        <p className="text-sm font-semibold mb-6" style={{ color: '#999' }}>
          כנס עם Google וצא לדרך 🚀
        </p>

        <button
          onClick={handleGoogleLogin}
          className="w-full flex items-center justify-center gap-3 rounded-2xl px-6 font-bold transition-all duration-200 active:scale-95"
          style={{
            height: '56px',
            background: '#fff',
            border: '2px solid #e8e8e8',
            color: '#2D2D2D',
            fontSize: '16px',
            boxShadow: '0 2px 8px rgba(0,0,0,0.06)'
          }}
          onMouseEnter={e => {
            e.currentTarget.style.borderColor = '#F15048'
            e.currentTarget.style.boxShadow = '0 4px 16px rgba(241,80,72,0.15)'
          }}
          onMouseLeave={e => {
            e.currentTarget.style.borderColor = '#e8e8e8'
            e.currentTarget.style.boxShadow = '0 2px 8px rgba(0,0,0,0.06)'
          }}
        >
          <GoogleIcon />
          <span>כניסה עם Google</span>
        </button>
      </div>

      <p className="mt-6 text-xs font-semibold animate-slide-up" style={{ color: '#bbb', animationDelay: '0.4s' }}>
        בחינם לחלוטין · לגילאי 9-13
      </p>
    </div>
  )
}

function GoogleIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24">
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
      <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
    </svg>
  )
}
