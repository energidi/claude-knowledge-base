import { useEffect, useRef } from 'react'

const COLORS = ['#F15048', '#6C63FF', '#2ECC71', '#FFB800', '#00BCD4', '#FF6B9D', '#FFF']
const SHAPES = ['circle', 'square', 'triangle']

function randomBetween(a, b) {
  return a + Math.random() * (b - a)
}

export default function Celebration({ onDone }) {
  const containerRef = useRef(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const pieces = []

    for (let i = 0; i < 60; i++) {
      const el = document.createElement('div')
      const color = COLORS[Math.floor(Math.random() * COLORS.length)]
      const size = randomBetween(6, 12)
      const startX = randomBetween(10, 90)
      const duration = randomBetween(1.8, 3.2)
      const delay = randomBetween(0, 0.6)
      const shape = SHAPES[Math.floor(Math.random() * SHAPES.length)]

      el.style.cssText = `
        position: fixed;
        left: ${startX}vw;
        top: -20px;
        width: ${size}px;
        height: ${size}px;
        background: ${shape === 'triangle' ? 'transparent' : color};
        border-radius: ${shape === 'circle' ? '50%' : shape === 'square' ? '2px' : '0'};
        ${shape === 'triangle' ? `
          width: 0; height: 0;
          border-left: ${size / 2}px solid transparent;
          border-right: ${size / 2}px solid transparent;
          border-bottom: ${size}px solid ${color};
          background: transparent;
        ` : ''}
        animation: confetti-fall ${duration}s ${delay}s linear forwards;
        z-index: 9999;
        pointer-events: none;
      `
      container.appendChild(el)
      pieces.push(el)
    }

    const timer = setTimeout(() => {
      pieces.forEach(p => p.remove())
      onDone()
    }, 3000)

    return () => {
      clearTimeout(timer)
      pieces.forEach(p => p.remove())
    }
  }, [onDone])

  return (
    <>
      <div ref={containerRef} />
      {/* Center celebration message */}
      <div
        className="fixed inset-0 flex items-center justify-center z-50 pointer-events-none"
        aria-hidden="true"
      >
        <div
          className="animate-pop-in text-center px-8 py-6 rounded-3xl"
          style={{
            background: 'rgba(255,255,255,0.95)',
            boxShadow: '0 20px 60px rgba(241,80,72,0.25)',
            backdropFilter: 'blur(8px)'
          }}
        >
          <div className="text-5xl mb-2">🏆</div>
          <p className="font-black text-2xl gradient-text">המשחק מוכן!</p>
          <p className="text-sm font-bold mt-1" style={{ color: '#bbb' }}>כל הכבוד! 🎉</p>
        </div>
      </div>
    </>
  )
}
