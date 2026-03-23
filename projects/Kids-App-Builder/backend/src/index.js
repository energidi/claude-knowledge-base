import 'dotenv/config'
import express from 'express'
import helmet from 'helmet'
import cors from 'cors'
import conversationRoutes from './routes/conversation.js'
import gamesRoutes from './routes/games.js'
import { verifyToken } from './middleware/auth.js'

const app = express()
const PORT = process.env.PORT || 3001

app.use(helmet())
app.use(cors({
  origin: process.env.FRONTEND_URL || 'http://localhost:5173',
  credentials: true
}))
app.use(express.json({ limit: '2mb' }))

// Health check
app.get('/api/health', (_req, res) => res.json({ status: 'ok' }))

// Protected routes
app.use('/api/conversation', verifyToken, conversationRoutes)
app.use('/api/games', verifyToken, gamesRoutes)

// Global error handler
app.use((err, _req, res, _next) => {
  console.error('[error]', err.message)
  res.status(err.status || 500).json({ error: err.message || 'שגיאה פנימית' })
})

app.listen(PORT, () => {
  console.log(`[playbuild-backend] listening on port ${PORT}`)
})
