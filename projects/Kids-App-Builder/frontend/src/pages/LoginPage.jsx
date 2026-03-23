import { supabase } from '../lib/supabase'

export default function LoginPage() {
  const handleGoogleLogin = async () => {
    await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: window.location.origin
      }
    })
  }

  return (
    <div className="min-h-screen bg-bg flex flex-col items-center justify-center px-6">
      <div className="mb-10 text-center">
        <h1 className="text-5xl font-black text-coral mb-2">PlayBuild</h1>
        <p className="text-lg text-text-secondary font-semibold">בנה משחקים עם בינה מלאכותית</p>
      </div>

      <div className="bg-white rounded-3xl shadow-lg p-8 w-full max-w-sm text-center">
        <p className="text-text-primary font-bold text-xl mb-6">כניסה לחשבון</p>
        <button
          onClick={handleGoogleLogin}
          className="w-full touch-target flex items-center justify-center gap-3 bg-white border-2 border-gray-200 rounded-2xl px-6 py-3 font-bold text-text-primary hover:border-coral hover:bg-coral/5 transition-all active:scale-95"
        >
          <img src="/icons/google.svg" alt="Google" className="w-6 h-6" />
          <span>כניסה עם Google</span>
        </button>
      </div>
    </div>
  )
}
