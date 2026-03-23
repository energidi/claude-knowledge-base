import { useEffect } from 'react'

const EMOJIS = ['🎉', '⭐', '🎮', '🚀', '✨', '🏆', '🎯', '💥']

/**
 * Full-screen celebration animation shown when a game is first generated.
 * Auto-dismisses after 2.5 seconds.
 */
export default function Celebration({ onDone }) {
  useEffect(() => {
    const timer = setTimeout(onDone, 2500)
    return () => clearTimeout(timer)
  }, [onDone])

  return (
    <div
      className="fixed inset-0 pointer-events-none z-40 overflow-hidden"
      aria-hidden="true"
    >
      {Array.from({ length: 20 }).map((_, i) => (
        <span
          key={i}
          className="absolute text-3xl animate-bounce"
          style={{
            left: `${Math.random() * 90}%`,
            top: `${Math.random() * 80}%`,
            animationDelay: `${Math.random() * 0.8}s`,
            animationDuration: `${0.6 + Math.random() * 0.6}s`,
            opacity: 0.9
          }}
        >
          {EMOJIS[i % EMOJIS.length]}
        </span>
      ))}
    </div>
  )
}
