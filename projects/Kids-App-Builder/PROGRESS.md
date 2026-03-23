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

## Pending

| Step | Notes |
|---|---|
| `npm install` | Blocked by company firewall - do from home or phone hotspot |
| `npm run dev` | Run after npm install succeeds |
| Cloudflare R2 setup | For game publishing - deferred |
| Cloudflare Worker deploy | For serving published games - deferred |
| Render.com backend deploy | For production hosting - deferred |
| Cloudflare Pages frontend deploy | For production hosting - deferred |
