# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**PlayBuild** - A Hebrew-language platform for children aged 9-13 to build simple 2D web games using natural language (conversational AI). The AI acts as a patient mentor, generating HTML/CSS/JS game code from chat or voice input.

**Target audience:** Hebrew-speaking kids aged 9-13. Multi-user from day one (Google OAuth per user). No parental consent gate in MVP - that's phase 2.

**MVP scope:** Core loop only: sign in -> chat -> game -> preview -> publish -> shareable URL.

**First test user:** 9.5-year-old boy (masculine Hebrew grammar used as test baseline).

## Target User

| Attribute | Value |
|---|---|
| Age range | 9-13 |
| Language | Hebrew |
| Device | Android mobile (primary) + desktop (secondary) |
| Experience | Plays games, no coding or app-building experience |
| Voice input | Yes - Web Speech API (`he-IL`, Chrome/Android) |
| Hebrew grammar | Dynamic - gender stored on profile (masculine/feminine/neutral) |

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| Frontend | React (PWA) | Mobile-first, responsive |
| Frontend hosting | Cloudflare Pages | Free, `playbuild.pages.dev` |
| Backend | Node.js | - |
| Backend hosting | Render.com | Free tier - cold starts after 15 min idle |
| AI Service | Anthropic Claude API | Personal key - swap before multi-user launch |
| Auth | Supabase Auth (Google OAuth) | Google sign-in only |
| Database | Supabase (PostgreSQL) | 500MB free |
| Game Storage | Cloudflare R2 | 10GB free |
| Game Serving | Cloudflare Worker | 100k req/day free - serves `playbuild.workers.dev/<game-id>` |
| Email | Resend.com | Phase 2 only (parental consent) |
| Language | Hebrew only, RTL | - |

> GitHub/Cloudflare Pages rejected as game-publishing pipeline. Games are static HTML objects in R2, served instantly via Worker - no build step, instant publish/revoke.

> Claude API is personal use only. Switch to Gemini free tier before opening to other users.

## Architecture

```
[React PWA] <-> [Node.js Backend] <-> [Claude API]
                      |
              [Supabase DB + Auth (Google OAuth)]
                      |
              [Cloudflare R2] -> [Cloudflare Worker] -> playbuild.workers.dev/<game-id>
```

## Core Data Flow

1. Kid types or speaks (Web Speech API) a game idea in Hebrew
2. Backend fetches user profile, builds system prompt, sends to Claude
3. Claude either asks one clarifying question OR generates final HTML/CSS/JS
4. Code rendered in sandboxed iframe (preview mode inside app)
5. Kid names the game (AI suggests a name if needed)
6. Kid publishes -> backend uploads HTML to R2 -> Worker serves shareable URL -> URL saved to DB

## Key Subsystems

**Conversation Engine** (`backend/src/conversation/`)
- System prompt includes: name, gender (for Hebrew grammar), age, safety rules, inspiration examples
- Max 3 clarifying questions before generating with best-effort assumptions
- If kid is stuck/vague: AI proactively offers suggestions to help describe the game
- On edit: send current game HTML + edit request to Claude (no prior conversation history needed)
- Games saved per user in Supabase; accessible and editable anytime
- **AI only asks about game behavior** (goals, characters, win/lose conditions, what happens when X). Never asks technical questions (colors, pixels, layout, fonts, speeds). All technical decisions are made autonomously by the AI with sensible defaults.

**Game Sandbox** (`frontend/src/components/GamePreview/`)
- iframe with `sandbox="allow-scripts"` ONLY - no network, no storage, no same-origin
- Error detection: catches JS exceptions, sends error back to Claude for self-correction (max 3 retries)
- Kid-friendly Hebrew error message shown if all retries fail
- Preview available inside app; published URL shareable externally

**Game Management**
- Each game has: id (UUID), name (kid-chosen, AI-assisted), HTML content, created_at, updated_at, published_url
- Kid names the game; if stuck, AI suggests a name in Hebrew
- Games listed on dashboard, each editable via new conversation

**Voice Input**
- Web Speech API, Hebrew (`lang="he-IL"`), Chrome/Android
- Fallback to text if browser doesn't support it
- Voice is in scope for MVP

**Content Moderation**
- Claude system prompt enforces: no violence, gore, adult themes
- Shooting mechanics allowed only at inanimate/abstract targets
- AI redirects unsafe requests playfully in Hebrew

**Localization**
- Hebrew only. No i18n library needed.
- RTL via `dir="rtl"` on root + CSS logical properties (`margin-inline-start` not `margin-left`)
- Generated game HTML must include `<html dir="rtl" lang="he">` and `<meta charset="UTF-8">`

## Visual Design

| Token | Value |
|---|---|
| Primary accent | `#F15048` (coral/orange) |
| Secondary | `#6C63FF` (purple) |
| Background | `#F8F9FA` (off-white) |
| Success | `#2ECC71` (green) |
| Text | `#2D2D2D` (dark gray) |
| Font | Nunito or Poppins (Google Fonts, free) |

- Style: sophisticated, not babyish - age 9-13, not 5
- Mobile-first, large touch targets
- Immediate visual feedback on every action
- Celebration animation when a game is successfully generated
- Inspiration chips on dashboard (examples only - kid brings their own idea)

## Environment Variables

```
ANTHROPIC_API_KEY=
SUPABASE_URL=
SUPABASE_SERVICE_KEY=
SUPABASE_ANON_KEY=
CLOUDFLARE_R2_ACCOUNT_ID=
CLOUDFLARE_R2_ACCESS_KEY_ID=
CLOUDFLARE_R2_SECRET_ACCESS_KEY=
CLOUDFLARE_R2_BUCKET_NAME=
GAMES_BASE_URL=        # https://playbuild.workers.dev
```

## Resolved Decisions

| Decision | Resolution |
|---|---|
| Auth | Google OAuth via Supabase |
| Voice input | Web Speech API (Hebrew, in MVP) |
| Game URL scheme | UUID |
| Game editing | Send current HTML + edit request to Claude (no history) |
| Parental consent | Phase 2 |
| Game versioning | Phase 2 |
| Domain | Free Cloudflare subdomains for MVP |
| App name | PlayBuild |
