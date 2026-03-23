# PlayBuild - Roadmap

## Phase 1 (MVP)
Multi-user (Google OAuth), core game-building loop. No parental consent gate yet. See CLAUDE.md for full spec.

## Phase 2

| Feature | Notes |
|---|---|
| Multi-user support | Registration, per-user accounts |
| Parental consent flow | Email approval before publishing (Resend.com); signed JWT link |
| Parent dashboard | View child's games, approve/revoke publishing |
| Content moderation layer | Secondary moderation pass (regex + Claude call) before rendering |
| Game versioning / history | Snapshot per save, ability to roll back |
| Voice input upgrade | Evaluate Web Speech API quality; consider Google Cloud STT if insufficient |
| Switch AI provider | Move from Claude API to Gemini free tier if scaling to many users |

## Phase 3 / Open Ideas

| Feature | Notes |
|---|---|
| Multiple children per parent account | Family plan |
| Monetization | Subscription if expanding beyond personal use |
| Game categories / tags | Browse games by type |
| Community gallery | Kids can see (approved) games built by others |
| Sound effects in generated games | AI includes audio via Web Audio API |
