import { Router } from 'express'
import { createClient } from '@supabase/supabase-js'
import { S3Client, PutObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3'
import { v4 as uuidv4 } from 'uuid'

const router = Router()

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
)

const r2 = new S3Client({
  region: 'auto',
  endpoint: `https://${process.env.CLOUDFLARE_R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: process.env.CLOUDFLARE_R2_ACCESS_KEY_ID,
    secretAccessKey: process.env.CLOUDFLARE_R2_SECRET_ACCESS_KEY
  }
})

/** GET /api/games - list user's games */
router.get('/', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('games')
      .select('id, name, published_url, created_at, updated_at')
      .eq('user_id', req.user.id)
      .order('updated_at', { ascending: false })

    if (error) return next(error)
    res.json({ games: data })
  } catch (err) {
    next(err)
  }
})

/** GET /api/games/:id - get single game */
router.get('/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('games')
      .select('id, name, html_content, published_url, created_at, updated_at')
      .eq('id', req.params.id)
      .eq('user_id', req.user.id)
      .single()

    if (error || !data) return res.status(404).json({ error: 'משחק לא נמצא' })
    res.json(data)
  } catch (err) {
    next(err)
  }
})

/** PATCH /api/games/:id/name - rename a game */
router.patch('/:id/name', async (req, res, next) => {
  try {
    const { name } = req.body
    if (!name?.trim()) return res.status(400).json({ error: 'שם ריק' })

    const { data, error } = await supabase
      .from('games')
      .update({ name: name.trim() })
      .eq('id', req.params.id)
      .eq('user_id', req.user.id)
      .select('id, name')
      .single()

    if (error) return next(error)
    res.json(data)
  } catch (err) {
    next(err)
  }
})

/** POST /api/games/:id/publish - upload game HTML to R2 and return public URL */
router.post('/:id/publish', async (req, res, next) => {
  try {
    const gameId = req.params.id
    const userId = req.user.id

    const { data: game, error } = await supabase
      .from('games')
      .select('id, html_content, name')
      .eq('id', gameId)
      .eq('user_id', userId)
      .single()

    if (error || !game) return res.status(404).json({ error: 'משחק לא נמצא' })
    if (!game.html_content) return res.status(400).json({ error: 'המשחק עוד לא נבנה' })

    await r2.send(new PutObjectCommand({
      Bucket: process.env.CLOUDFLARE_R2_BUCKET_NAME,
      Key: `${gameId}.html`,
      Body: game.html_content,
      ContentType: 'text/html; charset=utf-8'
    }))

    const publishedUrl = `${process.env.GAMES_BASE_URL}/${gameId}`

    await supabase
      .from('games')
      .update({ published_url: publishedUrl, published_at: new Date().toISOString() })
      .eq('id', gameId)

    res.json({ publishedUrl })
  } catch (err) {
    next(err)
  }
})

/** DELETE /api/games/:id - delete game and unpublish from R2 */
router.delete('/:id', async (req, res, next) => {
  try {
    const gameId = req.params.id
    const userId = req.user.id

    const { data: game } = await supabase
      .from('games')
      .select('published_url')
      .eq('id', gameId)
      .eq('user_id', userId)
      .single()

    if (game?.published_url) {
      await r2.send(new DeleteObjectCommand({
        Bucket: process.env.CLOUDFLARE_R2_BUCKET_NAME,
        Key: `${gameId}.html`
      })).catch(() => {}) // don't fail delete if R2 object is already gone
    }

    await supabase.from('games').delete().eq('id', gameId).eq('user_id', userId)

    res.json({ success: true })
  } catch (err) {
    next(err)
  }
})

export default router
