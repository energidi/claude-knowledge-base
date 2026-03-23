import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import api from '../lib/api'
import GamePreview from '../components/GamePreview'

export default function GamePage() {
  const { gameId } = useParams()
  const navigate = useNavigate()
  const [html, setHtml] = useState(null)
  const [gameName, setGameName] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    api.get(`/games/${gameId}`)
      .then(({ data }) => {
        setHtml(data.html_content)
        setGameName(data.name)
      })
      .finally(() => setLoading(false))
  }, [gameId])

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-bg">
        <div className="w-12 h-12 rounded-full border-4 border-coral border-t-transparent animate-spin" />
      </div>
    )
  }

  return (
    <div className="min-h-screen flex flex-col bg-gray-900">
      <header className="bg-black/40 px-4 py-3 flex items-center gap-3">
        <button
          onClick={() => navigate(-1)}
          className="text-white font-bold text-lg"
          aria-label="חזרה"
        >
          ←
        </button>
        <span className="text-white font-bold flex-1 truncate">{gameName}</span>
      </header>
      <div className="flex-1">
        <GamePreview gameId={gameId} html={html} />
      </div>
    </div>
  )
}
