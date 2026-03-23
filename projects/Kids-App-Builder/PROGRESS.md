# PlayBuild - Setup Progress

## Completed

| Step | Status | Notes |
|---|---|---|
| Supabase project created | done | "Kids App Builder", West EU region |
| Supabase SQL migration | done | All tables created: profiles, games, conversations + RLS |
| Supabase keys copied to .env | done | backend/.env + frontend/.env.local |
| Google Cloud project created | done | "Kids App Builder" |
| Google OAuth consent screen | done | App name: PlayBuild, External audience |
| Google OAuth client created | done | Redirect URI: https://zrjsswfgzodncudhrwvq.supabase.co/auth/v1/callback |
| Google OAuth connected to Supabase | done | Client ID + Secret pasted into Supabase Auth > Providers > Google |
| Anthropic API key | done | Pasted into backend/.env |
| Cloudflare account created | done | Energidi@gmail.com, PayPal billing |
| Cloudflare R2 bucket created | done | Bucket name: kids-app-builder |
| Cloudflare R2 API token created | done | Token name: Kids App Builder, Object Read & Write |
| Cloudflare R2 keys in backend/.env | done | Account ID, Access Key ID, Secret Access Key all filled in |

## Issues to Fix

| Issue | What to do |
|---|---|
| `SUPABASE_SERVICE_KEY` in backend/.env | Currently has the URL pasted there by mistake - replace with the actual Secret key from Supabase > Settings > API Keys |
| `CLOUDFLARE_R2_BUCKET_NAME` in backend/.env | Currently says `playbuild-games` - change to `kids-app-builder` |
| `GAMES_BASE_URL` in backend/.env | Currently says `https://playbuild.workers.dev` - update after Cloudflare Worker is deployed |

## Pending

| Step | Notes |
|---|---|
| `npm install` | Blocked by company firewall - do from home or phone hotspot |
| `npm run dev` | Run after npm install succeeds |
| Cloudflare Worker deploy | Serves published games at a public URL - needs `npm install` first |
| Render.com backend deploy | Production hosting for the backend |
| Cloudflare Pages frontend deploy | Production hosting for the frontend |
