import { Router } from 'express'
import { createClient } from '@supabase/supabase-js'
import { sendMessage, suggestGameName, fixGameCode } from '../services/claude.js'

const router = Router()

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
)

/**
 * POST /api/conversation/message
 * Body: { gameId, message }
 */
router.post('/message', async (req, res, next) => {
  try {
    const { gameId, message } = req.body
    const userId = req.user.id

    if (!message?.trim()) {
      return res.status(400).json({ error: 'הודעה ריקה' })
    }

    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('display_name, gender')
      .eq('id', userId)
      .single()

    if (profileError) return next(profileError)

    let game, conversation

    if (gameId) {
      const [gameRes, convRes] = await Promise.all([
        supabase.from('games').select('*').eq('id', gameId).eq('user_id', userId).single(),
        supabase.from('conversations').select('*').eq('game_id', gameId).eq('user_id', userId).single()
      ])

      if (gameRes.error) return res.status(404).json({ error: 'משחק לא נמצא' })
      game = gameRes.data

      if (convRes.error || !convRes.data) {
        const { data: newConv } = await supabase
          .from('conversations')
          .insert({ game_id: game.id, user_id: userId, messages: [] })
          .select()
          .single()
        conversation = newConv
      } else {
        conversation = convRes.data
      }
    } else {
      const { data: newGame } = await supabase
        .from('games')
        .insert({ user_id: userId })
        .select()
        .single()
      game = newGame

      const { data: newConv } = await supabase
        .from('conversations')
        .insert({ game_id: game.id, user_id: userId, messages: [] })
        .select()
        .single()
      conversation = newConv
    }

    const priorMessages = conversation.messages || []

    let contextualMessage = message
    if (gameId && game.html_content && priorMessages.length === 0) {
      contextualMessage = `הנה קוד המשחק הנוכחי:\n\`\`\`html\n${game.html_content}\n\`\`\`\n\nהשינוי שאני רוצה: ${message}`
    }

    const { reply, gameHtml } = await sendMessage({
      profile,
      messages: priorMessages,
      userMessage: contextualMessage
    })

    const updatedMessages = [
      ...priorMessages,
      { role: 'user', content: contextualMessage },
      { role: 'assistant', content: reply + (gameHtml ? '\nGAME_READY\n' + gameHtml : '') }
    ]

    await supabase
      .from('conversations')
      .update({ messages: updatedMessages })
      .eq('id', conversation.id)

    if (gameHtml) {
      await supabase
        .from('games')
        .update({ html_content: gameHtml })
        .eq('id', game.id)
    }

    res.json({ gameId: game.id, reply, gameHtml: gameHtml || null })
  } catch (err) {
    next(err)
  }
})

/**
 * POST /api/conversation/fix
 * Body: { gameId, html, error }
 */
router.post('/fix', async (req, res, next) => {
  try {
    const { gameId, html, error } = req.body
    const userId = req.user.id

    if (!html || !error) {
      return res.status(400).json({ error: 'חסרים פרמטרים' })
    }

    const fixedHtml = await fixGameCode({ gameHtml: html, errorMessage: error })

    if (gameId && fixedHtml) {
      await supabase
        .from('games')
        .update({ html_content: fixedHtml })
        .eq('id', gameId)
        .eq('user_id', userId)
    }

    res.json({ html: fixedHtml })
  } catch (err) {
    next(err)
  }
})

/**
 * POST /api/conversation/suggest-name
 * Body: { gameId }
 */
router.post('/suggest-name', async (req, res, next) => {
  try {
    const { gameId } = req.body
    const userId = req.user.id

    const { data: game, error } = await supabase
      .from('games')
      .select('html_content')
      .eq('id', gameId)
      .eq('user_id', userId)
      .single()

    if (error || !game?.html_content) {
      return res.status(404).json({ error: 'משחק לא נמצא' })
    }

    const { data: profile } = await supabase
      .from('profiles')
      .select('display_name')
      .eq('id', userId)
      .single()

    const name = await suggestGameName({ profile, gameHtml: game.html_content })
    res.json({ name })
  } catch (err) {
    next(err)
  }
})

export default router
