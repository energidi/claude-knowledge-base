# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**קוף החלל** (Space Chimp Runner) - Hebrew-language, space-themed endless runner. 10 levels, variable-height jumping, right-to-left scrolling, left-to-right meteors. No build step, no dependencies.

## Running the Game

Open `index.html` directly in a browser. No server, no npm, no build required.

For live reload during development:
```bash
# Any static server works, e.g.:
npx serve .
# or
python -m http.server 8080
```

## Architecture (game.js - single file, 20 numbered sections)

All logic lives in `game.js`. Sections are marked with `// SECTION N - NAME` comments.

| Section | Responsibility |
|---|---|
| 1 | Canvas setup and resize. Logical resolution is 800x400; `ctx.setTransform(scale,...)` is called on every resize so all draw coords stay in logical space. |
| 2 | `STATE` enum: `START`, `PLAYING`, `LEVEL_COMPLETE`, `GAME_OVER`, `VICTORY`. |
| 3 | `LEVELS[]` array (10 entries): `time`, `lives`, `spawnInterval`, `meteorSpeed`. |
| 4 | `CHARACTERS[]` - 4 emoji skins, cosmetic only. |
| 5-6 | Mutable game state vars + `GROUND_Y` constant (320px). |
| 7 | `player` object + physics constants. Variable jump uses `jumpPressed`/`jumpHeldSec`/`MAX_JUMP_HOLD`. |
| 8 | Meteor object pool (12 slots). Meteors spawn at `x = -radius`, move rightward (`+x`). `meteor.scored` prevents double-counting points. |
| 9 | Parallax background: `farStars`, `nearStars`, `planet`, `GROUND_MARKS`. All scroll left by subtracting `speed * dt` per frame and wrap at `x < 0`. |
| 10 | Web Audio API sound functions - no external files. |
| 11 | Input: keyboard (`keys` object) + mobile button wiring. Jump entry point is `onJumpPress()`. |
| 12 | `uiButtons[]` registry - cleared every frame, populated by `drawButton()` / `registerButton()`. `handleMenuClick()` hit-tests logical coords against it. |
| 13-14 | Circle-vs-AABB collision. `handlePlayerHit()`: decrement lives; 0 lives -> `STATE.GAME_OVER`; lives remain -> invincibility frames. |
| 15 | `startLevel(idx)` resets all mutable state. |
| 16 | `update(dt)` - called only in `STATE.PLAYING`. Delta time capped at 100ms. |
| 17-18 | Draw helpers (`roundRect`, `drawButton`) and scene renderers. |
| 19 | One draw function per screen state. |
| 20 | `gameLoop` via `requestAnimationFrame`. |

## Key Design Rules

- **Coordinate space**: always use logical coords (0-800, 0-400). Never multiply by `scale` inside game logic - only in `resizeCanvas`.
- **Delta time**: all movement uses `* dt` (seconds). `dt` is capped at `0.1` to prevent tunnelling on tab-switch.
- **Meteor direction**: meteors move in **+x** (rightward). Background scrolls in **-x** (leftward). These are independent systems.
- **Scoring**: awarded in `checkCollisions()` when `meteor.x > player.x && !player.onGround && !meteor.scored`.
- **Lives reset**: every call to `startLevel()` resets lives from `LEVELS[idx].lives` - score is NOT reset between levels.
- **Levels 1-5**: 1 life - any hit shows `GAME_OVER`. **Levels 6-10**: 3 lives - hits grant `INVINCIBLE_DUR = 2.0` seconds of blink.

## Adding Content

- **New level**: append an entry to `LEVELS[]` and update level-count references in comments.
- **New character**: append to `CHARACTERS[]` and add a card in `drawStartScreen()`.
- **New sound**: add a function using `playTone(type, freqStart, freqEnd, duration, volume)`.
- **New screen state**: add key to `STATE`, add draw function, add case in `gameLoop` switch.
