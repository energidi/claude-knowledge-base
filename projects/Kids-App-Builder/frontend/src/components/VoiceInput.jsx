import { useState, useRef, useCallback } from 'react'

const isSupported = typeof window !== 'undefined' &&
  ('SpeechRecognition' in window || 'webkitSpeechRecognition' in window)

export default function VoiceInput({ onTranscript, disabled }) {
  const [isListening, setIsListening] = useState(false)
  const recognitionRef = useRef(null)

  const startListening = useCallback(() => {
    if (!isSupported || isListening) return

    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition
    const recognition = new SpeechRecognition()

    recognition.lang = 'he-IL'
    recognition.continuous = false
    recognition.interimResults = false
    recognition.maxAlternatives = 1

    recognition.onstart = () => setIsListening(true)
    recognition.onresult = (event) => {
      onTranscript(event.results[0][0].transcript)
    }
    recognition.onerror = () => setIsListening(false)
    recognition.onend = () => setIsListening(false)

    recognitionRef.current = recognition
    recognition.start()
  }, [isListening, onTranscript])

  const stopListening = useCallback(() => {
    recognitionRef.current?.stop()
    setIsListening(false)
  }, [])

  if (!isSupported) return null

  return (
    <button
      type="button"
      onClick={isListening ? stopListening : startListening}
      disabled={disabled}
      aria-label={isListening ? 'עצור הקלטה' : 'דבר אל המיקרופון'}
      className="relative w-12 h-12 flex items-center justify-center rounded-full transition-all active:scale-90"
      style={{
        background: isListening
          ? 'linear-gradient(135deg, #F15048, #6C63FF)'
          : 'rgba(241,80,72,0.08)',
        boxShadow: isListening ? '0 4px 16px rgba(241,80,72,0.4)' : 'none',
        opacity: disabled ? 0.4 : 1,
        cursor: disabled ? 'not-allowed' : 'pointer'
      }}
    >
      {/* Pulse ring when listening */}
      {isListening && (
        <span className="absolute inset-0 rounded-full pulse-ring"
          style={{ background: 'rgba(241,80,72,0.3)' }} />
      )}

      {isListening ? (
        /* Stop icon */
        <svg width="18" height="18" viewBox="0 0 24 24" fill="white">
          <rect x="5" y="5" width="14" height="14" rx="2" />
        </svg>
      ) : (
        /* Mic icon */
        <svg width="18" height="18" viewBox="0 0 24 24" fill="#F15048">
          <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
          <path d="M19 10v2a7 7 0 0 1-14 0v-2H3v2a9 9 0 0 0 8 8.94V23h2v-2.06A9 9 0 0 0 21 12v-2h-2z" />
        </svg>
      )}
    </button>
  )
}
