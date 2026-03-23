import { useState, useRef, useCallback } from 'react'

const isSupported = typeof window !== 'undefined' &&
  ('SpeechRecognition' in window || 'webkitSpeechRecognition' in window)

/**
 * Voice input button using Web Speech API (Hebrew, he-IL).
 * Calls onTranscript(text) when speech is recognized.
 * Falls back gracefully if not supported.
 */
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
      const transcript = event.results[0][0].transcript
      onTranscript(transcript)
    }

    recognition.onerror = (event) => {
      console.warn('[voice] error:', event.error)
      setIsListening(false)
    }

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
      className={`
        touch-target flex items-center justify-center w-12 h-12 rounded-full transition-all active:scale-95
        ${isListening
          ? 'bg-coral text-white animate-pulse shadow-lg shadow-coral/40'
          : 'bg-gray-100 text-gray-500 hover:bg-coral/10 hover:text-coral'
        }
        ${disabled ? 'opacity-40 cursor-not-allowed' : 'cursor-pointer'}
      `}
    >
      {isListening ? (
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className="w-6 h-6">
          <path d="M6 6h12v12H6z" />
        </svg>
      ) : (
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" className="w-6 h-6">
          <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
          <path d="M19 10v2a7 7 0 0 1-14 0v-2H3v2a9 9 0 0 0 8 8.94V23h2v-2.06A9 9 0 0 0 21 12v-2h-2z" />
        </svg>
      )}
    </button>
  )
}
