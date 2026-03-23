import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export function useProfile(userId) {
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!userId) return

    supabase
      .from('profiles')
      .select('display_name, gender, avatar_url')
      .eq('id', userId)
      .single()
      .then(({ data }) => {
        setProfile(data)
        setLoading(false)
      })
  }, [userId])

  return { profile, loading }
}
