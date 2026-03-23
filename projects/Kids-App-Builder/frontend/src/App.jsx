import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import LoginPage from './pages/LoginPage'
import DashboardPage from './pages/DashboardPage'
import BuildPage from './pages/BuildPage'
import GamePage from './pages/GamePage'

function ProtectedRoute({ session, children }) {
  if (!session) return <Navigate to="/login" replace />
  return children
}

export default function App() {
  const [session, setSession] = useState(undefined) // undefined = loading

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session)
    })

    return () => subscription.unsubscribe()
  }, [])

  if (session === undefined) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-bg">
        <div className="w-12 h-12 rounded-full border-4 border-coral border-t-transparent animate-spin" />
      </div>
    )
  }

  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={session ? <Navigate to="/" replace /> : <LoginPage />} />
        <Route path="/" element={
          <ProtectedRoute session={session}>
            <DashboardPage session={session} />
          </ProtectedRoute>
        } />
        <Route path="/build" element={
          <ProtectedRoute session={session}>
            <BuildPage session={session} />
          </ProtectedRoute>
        } />
        <Route path="/build/:gameId" element={
          <ProtectedRoute session={session}>
            <BuildPage session={session} />
          </ProtectedRoute>
        } />
        <Route path="/game/:gameId" element={
          <ProtectedRoute session={session}>
            <GamePage session={session} />
          </ProtectedRoute>
        } />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
