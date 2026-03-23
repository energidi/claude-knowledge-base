# PlayBuild - Setup Guide

## 1. Install dependencies

```bash
npm install
```

## 2. Configure environment variables

```bash
cp backend/.env.example backend/.env
cp frontend/.env.example frontend/.env.local
```

Fill in both files:

### backend/.env
| Variable | Where to get it |
|---|---|
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `SUPABASE_URL` | Supabase project settings > API |
| `SUPABASE_SERVICE_KEY` | Supabase project settings > API > service_role key |
| `CLOUDFLARE_R2_ACCOUNT_ID` | Cloudflare dashboard > R2 |
| `CLOUDFLARE_R2_ACCESS_KEY_ID` | Cloudflare R2 > Manage API tokens |
| `CLOUDFLARE_R2_SECRET_ACCESS_KEY` | Same as above |
| `CLOUDFLARE_R2_BUCKET_NAME` | `playbuild-games` (create this bucket in R2) |
| `GAMES_BASE_URL` | `https://playbuild.workers.dev` (after worker deploy) |

### frontend/.env.local
| Variable | Where to get it |
|---|---|
| `VITE_SUPABASE_URL` | Same as SUPABASE_URL |
| `VITE_SUPABASE_ANON_KEY` | Supabase project settings > API > anon key |

## 3. Set up Supabase

1. Create a new Supabase project at supabase.com
2. Go to SQL Editor and run the contents of `supabase/migrations/001_initial_schema.sql`
3. Go to Authentication > Providers > enable Google OAuth
   - Add your Google OAuth client ID and secret
   - Set redirect URL to `http://localhost:5173` (dev) and your Cloudflare Pages URL (prod)

## 4. Deploy the Cloudflare Worker

```bash
cd worker
npm install
npx wrangler login
npx wrangler deploy
```

The worker URL will be `https://playbuild.<your-account>.workers.dev`.
Update `GAMES_BASE_URL` in `backend/.env` with this URL.

## 5. Run locally

```bash
npm run dev
```

- Frontend: http://localhost:5173
- Backend: http://localhost:3001

## 6. Deploy frontend to Cloudflare Pages

```bash
cd frontend
npm run build
```

Connect the `frontend/dist` folder to Cloudflare Pages via the dashboard.
Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as environment variables in Cloudflare Pages settings.
