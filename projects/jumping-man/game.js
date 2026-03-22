/* ============================================================
   קוף החלל - Space Chimp Runner
   Full game logic - Vanilla JS + Canvas API
   No external dependencies.
   ============================================================ */

'use strict';

// ============================================================
// SECTION 1 - CANVAS SETUP & RESIZE
// ============================================================

const canvas = document.getElementById('gameCanvas');
const ctx    = canvas.getContext('2d');

// Logical (design) resolution. All game coordinates use these values.
const LOGICAL_W = 800;
const LOGICAL_H = 400;

// Scale factor: how much we multiply logical coords to fill the window.
let scale = 1;

function resizeCanvas() {
  const winW  = window.innerWidth;
  const winH  = window.innerHeight;
  const scaleX = winW / LOGICAL_W;
  const scaleY = winH / LOGICAL_H;
  scale = Math.min(scaleX, scaleY);

  canvas.width  = Math.floor(LOGICAL_W * scale);
  canvas.height = Math.floor(LOGICAL_H * scale);

  // All subsequent draw calls are scaled automatically
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
}

window.addEventListener('resize', resizeCanvas);
resizeCanvas();

// ============================================================
// SECTION 2 - GAME STATES
// ============================================================

const STATE = {
  START          : 'START',
  PLAYING        : 'PLAYING',
  LEVEL_COMPLETE : 'LEVEL_COMPLETE',
  GAME_OVER      : 'GAME_OVER',
  VICTORY        : 'VICTORY',
  HISTORY        : 'HISTORY',
};

let gameState = STATE.START;

// ============================================================
// SECTION 2b - RECORDS (localStorage)
// ============================================================
// We store the best cumulative score achieved at the completion
// of each level, plus the date. Key format: "level0".."level9".

const STORAGE_KEY = 'kof-hachalal-records';

function loadRecords() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; }
  catch { return {}; }
}

// Save score for levelIdx if it beats the previous best.
// Returns true if this is a new record.
function trySaveRecord(levelIdx, newScore) {
  const records = loadRecords();
  const key     = `level${levelIdx}`;
  const prev    = records[key];
  if (!prev || newScore > prev.score) {
    records[key] = {
      score : newScore,
      date  : new Date().toLocaleDateString('he-IL'),
    };
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(records)); }
    catch { /* storage full - ignore */ }
    return true;
  }
  return false;
}

// ============================================================
// SECTION 2c - CONFETTI PARTICLES
// ============================================================

let confetti = [];

function launchConfetti() {
  confetti = [];
  const colors = ['#ff4444','#44ff88','#4488ff','#ffdd00','#ff88ff','#44ffff','#ffaa22'];
  for (let i = 0; i < 160; i++) {
    confetti.push({
      x       : Math.random() * LOGICAL_W,
      y       : -12,
      vx      : (Math.random() - 0.5) * 220,
      vy      : 80 + Math.random() * 180,
      color   : colors[Math.floor(Math.random() * colors.length)],
      w       : 6 + Math.random() * 8,
      h       : 4 + Math.random() * 5,
      rotation: Math.random() * Math.PI * 2,
      rotSpeed: (Math.random() - 0.5) * 7,
      alpha   : 1,
    });
  }
}

function updateConfetti(dt) {
  for (const p of confetti) {
    p.x        += p.vx * dt;
    p.y        += p.vy * dt;
    p.vy       += 140 * dt;   // gravity pulls confetti down
    p.rotation += p.rotSpeed * dt;
    p.alpha    -= 0.28 * dt;  // fade out over ~3.5 seconds
  }
  confetti = confetti.filter(p => p.alpha > 0 && p.y < LOGICAL_H + 20);
}

function drawConfetti() {
  for (const p of confetti) {
    ctx.save();
    ctx.globalAlpha = Math.max(0, p.alpha);
    ctx.translate(p.x, p.y);
    ctx.rotate(p.rotation);
    ctx.fillStyle = p.color;
    ctx.fillRect(-p.w / 2, -p.h / 2, p.w, p.h);
    ctx.restore();
  }
  ctx.globalAlpha = 1;
}

// Tracks whether the last level completion broke a record
let isNewRecord = false;

// ============================================================
// SECTION 3 - LEVEL CONFIGURATION
// ============================================================
// time          - seconds to survive
// lives         - starting lives for this level
// spawnInterval - ms between meteor spawns (lower = more frequent)
// meteorSpeed   - base pixels/sec for meteors

const LEVELS = [
  { time: 30,  lives: 1, spawnInterval: 2500, meteorSpeed: 180 },
  { time: 60,  lives: 1, spawnInterval: 2200, meteorSpeed: 200 },
  { time: 90,  lives: 1, spawnInterval: 2000, meteorSpeed: 220 },
  { time: 120, lives: 1, spawnInterval: 1800, meteorSpeed: 240 },
  { time: 150, lives: 1, spawnInterval: 1600, meteorSpeed: 260 },
  { time: 180, lives: 3, spawnInterval: 1400, meteorSpeed: 290 },
  { time: 210, lives: 3, spawnInterval: 1200, meteorSpeed: 320 },
  { time: 240, lives: 3, spawnInterval: 1000, meteorSpeed: 350 },
  { time: 270, lives: 3, spawnInterval: 800,  meteorSpeed: 390 },
  { time: 300, lives: 3, spawnInterval: 600,  meteorSpeed: 430 },
];

// ============================================================
// SECTION 4 - CHARACTERS
// ============================================================

const CHARACTERS = [
  { emoji: '🐒', name: 'אסטרו-שימפנזה' },
  { emoji: '🐈', name: 'אסטרו-חתול'    },
  { emoji: '🤖', name: 'רובוט חלוד'    },
  { emoji: '👽', name: 'זלוג הבלוב'    },
];

let selectedCharIdx = 0;

// ============================================================
// SECTION 5 - MUTABLE GAME STATE
// ============================================================

let currentLevel  = 0;
let score         = 0;
let lives         = 1;
let timeRemaining = 0;
let lastTimestamp  = 0;

// ============================================================
// SECTION 6 - GROUND
// ============================================================

const GROUND_Y = 320; // Y-position of the ground line (logical px)

// ============================================================
// SECTION 7 - PLAYER
// ============================================================
// VARIABLE JUMP EXPLAINED:
//   The jump system has two phases:
//   Phase 1 - Impulse: On Space keydown (while on ground), vy is set to
//             JUMP_VY (a large negative value). This launches the player up.
//   Phase 2 - Hold Boost: While Space is held AND the player is still rising
//             AND jumpHeldSec < MAX_JUMP_HOLD, an extra upward force
//             (HOLD_BOOST) is subtracted from vy each frame.
//             This extends the jump height the longer you hold.
//   When Space is released, jumpPressed = false, boost stops.
//   Result: tap = short hop, hold = tall jump. Max height is capped.
//
//   Gravity (GRAVITY px/sec^2) is always applied, whether on ground or not.
//   When player.y reaches GROUND_Y the player lands and vy resets to 0.

const GRAVITY       = 1400;  // downward acceleration (px/sec^2)
const JUMP_VY       = -520;  // initial upward velocity on jump (px/sec)
const HOLD_BOOST    = 900;   // extra upward acceleration while holding (px/sec^2)
const MAX_JUMP_HOLD = 0.38;  // max seconds the hold boost is applied
const PLAYER_SPEED_X = 180;  // horizontal movement speed (px/sec)
const PLAYER_MIN_X   = 80;
const PLAYER_MAX_X   = LOGICAL_W - 80;

const player = {
  x             : 560,
  y             : GROUND_Y,
  vy            : 0,
  onGround      : true,
  jumpPressed   : false,   // true while Space is held on a jump
  jumpHeldSec   : 0,       // seconds Space has been held this jump
  invincible    : false,
  invincibleTimer : 0,
  INVINCIBLE_DUR  : 2.0,
  size          : 44,      // emoji font size
};

// ============================================================
// SECTION 8 - METEORS
// ============================================================
// RIGHT-TO-LEFT RUNNING EXPLAINED:
//   The player character conceptually runs from RIGHT to LEFT through space.
//   We simulate this by scrolling all background layers from right to left
//   (subtracting dx from their X positions each frame).
//
//   Meteors are rocks rolling toward the player. Since the player runs left,
//   meteors come from the LEFT and roll RIGHTWARD (toward the player):
//     - Meteors spawn at x = -radius (just off the left edge of the screen)
//     - Each frame: meteor.x += meteor.speed * dt  (positive X = rightward)
//     - When meteor.x > LOGICAL_W + radius, it is recycled
//
//   This creates the feel of running head-on into incoming space debris.
//
// SCORING:
//   A point is awarded when a meteor crosses the player's X position
//   while the player is airborne. This means the player successfully
//   jumped over the rolling rock.
//   Tracked with meteor.scored to prevent double-counting.

const METEOR_POOL_SIZE = 12;
const meteors = [];

for (let i = 0; i < METEOR_POOL_SIZE; i++) {
  meteors.push({
    x: 0, y: 0,
    radius  : 24,
    speed   : 0,
    active  : false,
    scored  : false,
    rotation: 0,
  });
}

let spawnTimer = 0; // ms since last spawn

function getFreeMeteor() {
  for (const m of meteors) {
    if (!m.active) return m;
  }
  return null;
}

function spawnMeteor() {
  const m = getFreeMeteor();
  if (!m) return;
  const cfg   = LEVELS[currentLevel];
  m.radius    = 18 + Math.random() * 18;
  m.x         = -m.radius;
  m.y         = GROUND_Y - m.radius;
  m.speed     = cfg.meteorSpeed * (0.85 + Math.random() * 0.3);
  m.active    = true;
  m.scored    = false;
  m.rotation  = 0;
}

// ============================================================
// SECTION 9 - PARALLAX BACKGROUND
// ============================================================
// SCROLLING EXPLAINED:
//   Stars and the planet have an X position that decreases by
//   (speed * dt) every frame. This moves them leftward, simulating
//   the player running to the left through space.
//
//   Different layers scroll at different speeds to create depth:
//     Far stars:  speed = BG_BASE_SPEED * 0.15 (very slow, far away)
//     Near stars: speed = BG_BASE_SPEED * 0.40 (faster, closer)
//     Planet:     speed = BG_BASE_SPEED * 0.06 (barely moves, very far)
//
//   When an element exits the left edge, it wraps to the right edge.

const BG_BASE_SPEED = 80; // reference scroll speed (px/sec)

function makeStarLayer(count, speedMult, minR, maxR) {
  const arr = [];
  for (let i = 0; i < count; i++) {
    arr.push({
      x    : Math.random() * LOGICAL_W,
      y    : Math.random() * (GROUND_Y - 20),
      r    : minR + Math.random() * (maxR - minR),
      speed: BG_BASE_SPEED * speedMult,
      alpha: 0.4 + Math.random() * 0.6,
    });
  }
  return arr;
}

const farStars  = makeStarLayer(80, 0.15, 0.5, 1.2);
const nearStars = makeStarLayer(30, 0.40, 1.0, 2.5);

const planet = { x: LOGICAL_W * 0.25, y: 110, r: 55, speed: BG_BASE_SPEED * 0.06 };

// Ground tick marks that scroll with the background
const GROUND_MARKS = [];
for (let i = 0; i < 14; i++) {
  GROUND_MARKS.push({ x: i * (LOGICAL_W / 11) });
}
const GROUND_MARK_SPEED = BG_BASE_SPEED * 1.0;

// ============================================================
// SECTION 10 - WEB AUDIO (SFX + BACKGROUND MUSIC)
// ============================================================
// One shared AudioContext for all audio.
// Sound effects connect directly to destination.
// Music has its own GainNode (musicGain) so it can be muted
// independently without silencing jump/hit sounds.
//
// BACKGROUND MUSIC DESIGN:
//   A slow ambient arpeggio using A-minor pentatonic frequencies.
//   Two layers: a bass note every 4 beats, and a melodic arpeggio.
//   Notes are scheduled ~200ms ahead using a recurring setTimeout
//   (the "audio scheduler" pattern) so timing stays tight even if
//   the main thread is busy rendering.

let audioCtx  = null;
let musicGain = null;       // controls music volume only
let isMuted   = false;
let musicSchedulerTimer = null;
let nextNoteTime = 0;
let musicBeatIdx = 0;
let musicStarted = false;

// Am-pentatonic melody (Hz): A2 E3 G3 A3 C4 E4 G4 A4
const MUSIC_MELODY = [110, 165, 196, 220, 261, 330, 392, 220,
                      196, 165, 220, 261, 196, 165, 110, 165];
const MUSIC_BEAT_DUR = 0.55; // seconds per arpeggio step (slow, ambient)
const MUSIC_VOL      = 0.18; // master music volume when unmuted

function getAudioCtx() {
  if (!audioCtx) {
    audioCtx  = new (window.AudioContext || window.webkitAudioContext)();
    musicGain = audioCtx.createGain();
    musicGain.gain.value = isMuted ? 0 : MUSIC_VOL;
    musicGain.connect(audioCtx.destination);
  }
  return audioCtx;
}

// Schedule one melodic note at `when` seconds (AudioContext time)
function scheduleMusicNote(freq, when) {
  const ac  = getAudioCtx();
  const dur = MUSIC_BEAT_DUR * 0.85;

  // Sine wave body
  const osc  = ac.createOscillator();
  const env  = ac.createGain();
  osc.connect(env);
  env.connect(musicGain);
  osc.type = 'sine';
  osc.frequency.value = freq;
  env.gain.setValueAtTime(0, when);
  env.gain.linearRampToValueAtTime(0.5, when + 0.06);
  env.gain.exponentialRampToValueAtTime(0.001, when + dur);
  osc.start(when);
  osc.stop(when + dur + 0.01);

  // Subtle triangle overtone for warmth
  const osc2 = ac.createOscillator();
  const env2 = ac.createGain();
  osc2.connect(env2);
  env2.connect(musicGain);
  osc2.type = 'triangle';
  osc2.frequency.value = freq * 2;
  env2.gain.setValueAtTime(0, when);
  env2.gain.linearRampToValueAtTime(0.12, when + 0.06);
  env2.gain.exponentialRampToValueAtTime(0.001, when + dur);
  osc2.start(when);
  osc2.stop(when + dur + 0.01);

  // Bass pulse every 4 beats
  if (musicBeatIdx % 4 === 0) {
    const bass  = ac.createOscillator();
    const bassG = ac.createGain();
    bass.connect(bassG);
    bassG.connect(musicGain);
    bass.type = 'sine';
    bass.frequency.value = MUSIC_MELODY[0] / 2; // A1 - deep bass
    bassG.gain.setValueAtTime(0, when);
    bassG.gain.linearRampToValueAtTime(0.4, when + 0.08);
    bassG.gain.exponentialRampToValueAtTime(0.001, when + MUSIC_BEAT_DUR * 3.8);
    bass.start(when);
    bass.stop(when + MUSIC_BEAT_DUR * 4);
  }
}

// Scheduler tick: look 200ms ahead and queue any notes due in that window
function musicSchedulerTick() {
  const ac = getAudioCtx();
  const LOOKAHEAD = 0.2; // seconds

  while (nextNoteTime < ac.currentTime + LOOKAHEAD) {
    scheduleMusicNote(
      MUSIC_MELODY[musicBeatIdx % MUSIC_MELODY.length],
      nextNoteTime
    );
    musicBeatIdx++;
    nextNoteTime += MUSIC_BEAT_DUR;
  }

  musicSchedulerTimer = setTimeout(musicSchedulerTick, 50);
}

function startBackgroundMusic() {
  if (musicStarted) return;
  musicStarted = true;
  try {
    const ac = getAudioCtx();
    // Resume context if browser suspended it (autoplay policy)
    if (ac.state === 'suspended') ac.resume();
    nextNoteTime = ac.currentTime + 0.1;
    musicBeatIdx = 0;
    musicSchedulerTick();
  } catch (e) { /* ignore */ }
}

function toggleMute() {
  isMuted = !isMuted;
  const ac = getAudioCtx();
  // Smooth fade instead of abrupt cut
  musicGain.gain.setTargetAtTime(
    isMuted ? 0 : MUSIC_VOL,
    ac.currentTime,
    0.15
  );
  // Persist preference
  try { localStorage.setItem('kof-hachalal-muted', isMuted ? '1' : '0'); }
  catch { /* ignore */ }
  updateMuteButton();
}

function updateMuteButton() {
  const btn = document.getElementById('btn-mute');
  if (btn) btn.textContent = isMuted ? '🔇' : '🔊';
}

// Restore saved mute preference
try {
  isMuted = localStorage.getItem('kof-hachalal-muted') === '1';
} catch { isMuted = false; }

// SFX functions (connect directly to destination, not affected by mute)
function playTone(type, freqStart, freqEnd, duration, volume = 0.3) {
  try {
    const ac   = getAudioCtx();
    if (ac.state === 'suspended') ac.resume();
    const osc  = ac.createOscillator();
    const gain = ac.createGain();
    osc.connect(gain);
    gain.connect(ac.destination);
    osc.type = type;
    osc.frequency.setValueAtTime(freqStart, ac.currentTime);
    osc.frequency.linearRampToValueAtTime(freqEnd, ac.currentTime + duration);
    gain.gain.setValueAtTime(volume, ac.currentTime);
    gain.gain.linearRampToValueAtTime(0, ac.currentTime + duration);
    osc.start(ac.currentTime);
    osc.stop(ac.currentTime + duration + 0.02);
  } catch (e) { /* Audio blocked before user gesture - ignore */ }
}

function soundJump()          { playTone('sine',     300, 560, 0.08, 0.2);  }
function soundHit()           { playTone('sawtooth', 220, 80,  0.18, 0.35); }
function soundLevelComplete() {
  playTone('sine', 523, 523, 0.12, 0.3);
  setTimeout(() => playTone('sine', 659, 659, 0.12, 0.3), 140);
  setTimeout(() => playTone('sine', 784, 784, 0.18, 0.3), 280);
}
function soundVictory() {
  [523, 587, 659, 698, 784, 880, 988, 1047].forEach((f, i) => {
    setTimeout(() => playTone('sine', f, f, 0.15, 0.3), i * 130);
  });
}

// ============================================================
// SECTION 11 - INPUT
// ============================================================

const keys = { ArrowLeft: false, ArrowRight: false, Space: false };

function onJumpPress() {
  startBackgroundMusic();
  // Start a jump only from the ground and only if key wasn't already held
  if (!keys.Space && player.onGround && gameState === STATE.PLAYING) {
    player.vy          = JUMP_VY;
    player.onGround    = false;
    player.jumpPressed = true;
    player.jumpHeldSec = 0;
    soundJump();
  }
  keys.Space = true;
}

function onJumpRelease() {
  keys.Space         = false;
  player.jumpPressed = false; // ends hold boost
}

window.addEventListener('keydown', (e) => {
  if (e.code === 'ArrowLeft')  { keys.ArrowLeft  = true; e.preventDefault(); }
  if (e.code === 'ArrowRight') { keys.ArrowRight = true; e.preventDefault(); }
  if (e.code === 'Space')      { e.preventDefault(); onJumpPress(); }
});

window.addEventListener('keyup', (e) => {
  if (e.code === 'ArrowLeft')  keys.ArrowLeft  = false;
  if (e.code === 'ArrowRight') keys.ArrowRight = false;
  if (e.code === 'Space')      onJumpRelease();
});

// Mobile button wiring
function wireButton(btnId, downFn, upFn) {
  const btn = document.getElementById(btnId);
  if (!btn) return;
  const down = (e) => { e.preventDefault(); btn.classList.add('pressed');    downFn(); };
  const up   = (e) => { e.preventDefault(); btn.classList.remove('pressed'); upFn();   };
  btn.addEventListener('touchstart',  down, { passive: false });
  btn.addEventListener('touchend',    up,   { passive: false });
  btn.addEventListener('touchcancel', up,   { passive: false });
  btn.addEventListener('mousedown',   down);
  btn.addEventListener('mouseup',     up);
  btn.addEventListener('mouseleave',  up);
}

wireButton('btn-left',
  () => { keys.ArrowLeft = true;  },
  () => { keys.ArrowLeft = false; }
);
wireButton('btn-right',
  () => { keys.ArrowRight = true;  },
  () => { keys.ArrowRight = false; }
);
wireButton('btn-jump', onJumpPress, onJumpRelease);

// ============================================================
// SECTION 12 - UI BUTTON REGISTRY (click / tap on canvas)
// ============================================================

let uiButtons = [];

function registerButton(id, x, y, w, h) {
  uiButtons.push({ id, x, y, w, h });
}

canvas.addEventListener('click', (e) => {
  const rect = canvas.getBoundingClientRect();
  const lx = (e.clientX - rect.left) / scale;
  const ly = (e.clientY - rect.top)  / scale;
  handleMenuClick(lx, ly);
});

canvas.addEventListener('touchend', (e) => {
  const t    = e.changedTouches[0];
  const rect = canvas.getBoundingClientRect();
  const lx = (t.clientX - rect.left) / scale;
  const ly = (t.clientY - rect.top)  / scale;
  handleMenuClick(lx, ly);
}, { passive: true });

function handleMenuClick(lx, ly) {
  for (const btn of uiButtons) {
    if (lx >= btn.x && lx <= btn.x + btn.w &&
        ly >= btn.y && ly <= btn.y + btn.h) {
      onButtonClick(btn.id);
      return;
    }
  }
}

function onButtonClick(id) {
  startBackgroundMusic(); // first click = first user gesture = safe to start audio
  if (id === 'start')         { startLevel(0); return; }
  if (id === 'next-level')    { startLevel(currentLevel + 1); return; }
  if (id === 'try-again')     { startLevel(currentLevel); return; }
  if (id === 'restart')       { score = 0; startLevel(0); return; }
  if (id === 'history')       { gameState = STATE.HISTORY; return; }
  if (id === 'back-to-start') { gameState = STATE.START;   return; }
  if (id.startsWith('char-')) {
    selectedCharIdx = parseInt(id.split('-')[1], 10);
  }
}

// ============================================================
// SECTION 13 - COLLISION DETECTION
// ============================================================

// Circle vs AABB (axis-aligned bounding box) overlap test.
function circleRectOverlap(cx, cy, cr, rx, ry, rw, rh) {
  const nearX = Math.max(rx, Math.min(cx, rx + rw));
  const nearY = Math.max(ry, Math.min(cy, ry + rh));
  const dx = cx - nearX;
  const dy = cy - nearY;
  return (dx * dx + dy * dy) < (cr * cr);
}

function checkCollisions() {
  // Player AABB (shrunk slightly so emoji edges don't trigger unfairly)
  const hw     = player.size * 0.35;
  const shrink = 8;
  const px = player.x - hw + shrink;
  const py = player.y - player.size + shrink;
  const pw = hw * 2 - shrink * 2;
  const ph = player.size - shrink;

  for (const m of meteors) {
    if (!m.active) continue;

    // Score: meteor crossed player's X while player is airborne
    if (!m.scored && m.x > player.x && !player.onGround) {
      m.scored = true;
      score++;
    }

    // Hit detection: skip if invincible
    if (player.invincible) continue;

    if (circleRectOverlap(m.x, m.y, m.radius * 0.85, px, py, pw, ph)) {
      handlePlayerHit();
      break; // process one hit per frame
    }
  }
}

// ============================================================
// SECTION 14 - HIT / LIVES LOGIC
// ============================================================

function handlePlayerHit() {
  soundHit();
  lives--;

  if (lives <= 0) {
    // No lives left - show Game Over screen
    gameState = STATE.GAME_OVER;
    return;
  }

  // Lives remain (levels 6-10 with 3 lives): grant invincibility frames
  player.invincible       = true;
  player.invincibleTimer  = player.INVINCIBLE_DUR;
}

// ============================================================
// SECTION 15 - LEVEL MANAGEMENT
// ============================================================

function startLevel(levelIdx) {
  currentLevel  = levelIdx;
  const cfg     = LEVELS[currentLevel];
  lives         = cfg.lives;
  timeRemaining = cfg.time;
  spawnTimer    = 0;

  // Reset meteor pool
  for (const m of meteors) m.active = false;

  // Reset player
  player.x              = 560;
  player.y              = GROUND_Y;
  player.vy             = 0;
  player.onGround       = true;
  player.jumpPressed    = false;
  player.jumpHeldSec    = 0;
  player.invincible     = false;
  player.invincibleTimer = 0;

  // Reset input state
  keys.ArrowLeft  = false;
  keys.ArrowRight = false;
  keys.Space      = false;

  gameState = STATE.PLAYING;
}

// ============================================================
// SECTION 16 - UPDATE
// ============================================================

function update(dt) {
  // Confetti runs on level-complete and victory screens too
  if (confetti.length > 0) updateConfetti(dt);

  if (gameState !== STATE.PLAYING) return;

  // -- Timer --
  timeRemaining -= dt;
  if (timeRemaining <= 0) {
    timeRemaining = 0;
    // Level survived!
    isNewRecord = trySaveRecord(currentLevel, score);
    if (isNewRecord) launchConfetti();

    if (currentLevel >= LEVELS.length - 1) {
      gameState = STATE.VICTORY;
      soundVictory();
    } else {
      gameState = STATE.LEVEL_COMPLETE;
      soundLevelComplete();
    }
    return;
  }

  // -- Player horizontal (arrow keys adjust position to time jumps) --
  if (keys.ArrowLeft)  player.x = Math.max(PLAYER_MIN_X, player.x - PLAYER_SPEED_X * dt);
  if (keys.ArrowRight) player.x = Math.min(PLAYER_MAX_X, player.x + PLAYER_SPEED_X * dt);

  // -- Variable jump: hold boost phase --
  // While Space is held, player is airborne, and hold time not exhausted:
  // apply additional upward acceleration to extend jump height.
  if (player.jumpPressed && !player.onGround) {
    if (player.jumpHeldSec < MAX_JUMP_HOLD) {
      player.vy          -= HOLD_BOOST * dt;
      player.jumpHeldSec += dt;
    } else {
      player.jumpPressed = false; // cap reached - stop boost
    }
  }

  // -- Gravity (always applied) --
  player.vy += GRAVITY * dt;

  // -- Vertical position --
  player.y += player.vy * dt;

  // -- Ground landing --
  if (player.y >= GROUND_Y) {
    player.y           = GROUND_Y;
    player.vy          = 0;
    player.onGround    = true;
    player.jumpPressed = false;
  }

  // -- Invincibility countdown --
  if (player.invincible) {
    player.invincibleTimer -= dt;
    if (player.invincibleTimer <= 0) player.invincible = false;
  }

  // -- Meteor spawning --
  spawnTimer += dt * 1000;
  if (spawnTimer >= LEVELS[currentLevel].spawnInterval) {
    spawnTimer = 0;
    spawnMeteor();
  }

  // -- Meteor movement --
  for (const m of meteors) {
    if (!m.active) continue;
    m.x        += m.speed * dt;
    m.rotation += (m.speed / m.radius) * dt; // rolling effect
    if (m.x > LOGICAL_W + m.radius) m.active = false; // recycle
  }

  // -- Background scroll (right-to-left parallax) --
  for (const s of farStars) {
    s.x -= s.speed * dt;
    if (s.x < 0) s.x += LOGICAL_W;
  }
  for (const s of nearStars) {
    s.x -= s.speed * dt;
    if (s.x < 0) s.x += LOGICAL_W;
  }
  planet.x -= planet.speed * dt;
  if (planet.x < -planet.r * 2) planet.x = LOGICAL_W + planet.r;

  for (const mark of GROUND_MARKS) {
    mark.x -= GROUND_MARK_SPEED * dt;
    if (mark.x < -20) mark.x += LOGICAL_W + 20;
  }

  // -- Collisions --
  checkCollisions();
}

// ============================================================
// SECTION 17 - DRAW HELPERS
// ============================================================

function roundRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
}

function drawButton(id, label, x, y, w, h, bgColor = '#1a6aff') {
  ctx.save();
  ctx.shadowColor = '#003388';
  ctx.shadowBlur  = 14;
  ctx.fillStyle   = bgColor;
  roundRect(x, y, w, h, 10);
  ctx.fill();
  ctx.shadowBlur  = 0;
  ctx.strokeStyle = 'rgba(255,255,255,0.3)';
  ctx.lineWidth   = 1.5;
  ctx.stroke();
  ctx.fillStyle    = '#fff';
  ctx.font         = `bold ${Math.round(h * 0.42)}px Arial`;
  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(label, x + w / 2, y + h / 2);
  ctx.restore();
  registerButton(id, x, y, w, h);
}

// ============================================================
// SECTION 18 - DRAW SCENE ELEMENTS
// ============================================================

function drawBackground() {
  // Sky gradient
  const grad = ctx.createLinearGradient(0, 0, 0, GROUND_Y);
  grad.addColorStop(0, '#020818');
  grad.addColorStop(1, '#0a1a3a');
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, LOGICAL_W, LOGICAL_H);

  // Planet
  ctx.save();
  ctx.globalAlpha = 0.55;
  const pg = ctx.createRadialGradient(
    planet.x - planet.r * 0.3, planet.y - planet.r * 0.3, planet.r * 0.1,
    planet.x, planet.y, planet.r
  );
  pg.addColorStop(0, '#6070c0');
  pg.addColorStop(1, '#1a2550');
  ctx.fillStyle = pg;
  ctx.beginPath();
  ctx.arc(planet.x, planet.y, planet.r, 0, Math.PI * 2);
  ctx.fill();
  ctx.strokeStyle = 'rgba(150,170,255,0.3)';
  ctx.lineWidth   = 4;
  ctx.beginPath();
  ctx.ellipse(planet.x, planet.y, planet.r * 1.7, planet.r * 0.35, -0.3, 0, Math.PI * 2);
  ctx.stroke();
  ctx.restore();

  // Far stars
  ctx.fillStyle = '#ffffff';
  for (const s of farStars) {
    ctx.globalAlpha = s.alpha * 0.7;
    ctx.beginPath();
    ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
    ctx.fill();
  }
  // Near stars
  ctx.fillStyle = '#cce0ff';
  for (const s of nearStars) {
    ctx.globalAlpha = s.alpha;
    ctx.beginPath();
    ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;
}

function drawGround() {
  const g = ctx.createLinearGradient(0, GROUND_Y, 0, LOGICAL_H);
  g.addColorStop(0, '#3a3060');
  g.addColorStop(1, '#1a1030');
  ctx.fillStyle = g;
  ctx.fillRect(0, GROUND_Y, LOGICAL_W, LOGICAL_H - GROUND_Y);

  ctx.strokeStyle = '#7060cc';
  ctx.lineWidth   = 2;
  ctx.beginPath();
  ctx.moveTo(0, GROUND_Y);
  ctx.lineTo(LOGICAL_W, GROUND_Y);
  ctx.stroke();

  ctx.strokeStyle = 'rgba(150,130,220,0.4)';
  ctx.lineWidth   = 1;
  for (const mark of GROUND_MARKS) {
    ctx.beginPath();
    ctx.moveTo(mark.x, GROUND_Y);
    ctx.lineTo(mark.x, GROUND_Y + 8);
    ctx.stroke();
  }
}

function drawPlayer() {
  // Blink effect during invincibility
  if (player.invincible) {
    const blinkOn = Math.floor(player.invincibleTimer * 8) % 2 === 0;
    if (blinkOn) return;
  }
  ctx.save();
  ctx.font         = `${player.size}px serif`;
  ctx.textAlign    = 'center';
  ctx.textBaseline = 'bottom';
  ctx.shadowColor  = 'rgba(100,200,255,0.6)';
  ctx.shadowBlur   = 14;
  ctx.fillText(CHARACTERS[selectedCharIdx].emoji, player.x, player.y);
  ctx.restore();
}

function drawMeteors() {
  for (const m of meteors) {
    if (!m.active) continue;
    ctx.save();
    ctx.translate(m.x, m.y);
    ctx.rotate(m.rotation);
    const mg = ctx.createRadialGradient(-m.radius * 0.3, -m.radius * 0.3, 1, 0, 0, m.radius);
    mg.addColorStop(0, '#ff8844');
    mg.addColorStop(0.5, '#cc3300');
    mg.addColorStop(1, '#661100');
    ctx.fillStyle   = mg;
    ctx.shadowColor = '#ff4400';
    ctx.shadowBlur  = 10;
    ctx.beginPath();
    ctx.arc(0, 0, m.radius, 0, Math.PI * 2);
    ctx.fill();
    ctx.shadowBlur   = 0;
    ctx.font         = `${Math.round(m.radius * 1.5)}px serif`;
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('☄️', 0, 0);
    ctx.restore();
  }
}

function drawHUD() {
  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(0, 0, LOGICAL_W, 40);

  ctx.font         = 'bold 18px Arial';
  ctx.textBaseline = 'middle';

  // Level (right side - RTL)
  ctx.fillStyle = '#aaccff';
  ctx.textAlign = 'right';
  ctx.fillText(`שלב: ${currentLevel + 1}`, LOGICAL_W - 12, 14);

  // Time (center)
  const secs = Math.ceil(timeRemaining);
  ctx.fillStyle = secs <= 10 ? '#ff5555' : '#ffffff';
  ctx.textAlign = 'center';
  ctx.fillText(`זמן: ${secs}`, LOGICAL_W / 2, 14);

  // Score (left)
  ctx.fillStyle = '#ffdd44';
  ctx.textAlign = 'left';
  ctx.fillText(`ניקוד: ${score}`, 12, 14);

  // Lives (hearts below score)
  let hearts = '';
  const maxLives = LEVELS[currentLevel].lives;
  for (let i = 0; i < maxLives; i++) {
    hearts += i < lives ? '❤️' : '🖤';
  }
  ctx.font = '14px serif';
  ctx.fillText(hearts, 12, 32);

  ctx.restore();
}

// ============================================================
// SECTION 19 - SCREEN DRAW FUNCTIONS
// ============================================================

function drawStartScreen() {
  drawBackground();

  ctx.save();
  // Title
  ctx.font         = 'bold 52px Arial';
  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle    = '#ffffff';
  ctx.shadowColor  = '#4488ff';
  ctx.shadowBlur   = 24;
  ctx.fillText('קוף החלל', LOGICAL_W / 2, 70);
  ctx.shadowBlur   = 0;

  ctx.font      = '20px Arial';
  ctx.fillStyle = '#8899cc';
  ctx.fillText('משחק ריצה בחלל', LOGICAL_W / 2, 110);

  ctx.font      = 'bold 18px Arial';
  ctx.fillStyle = '#ccddff';
  ctx.fillText('בחר את הדמות שלך', LOGICAL_W / 2, 155);
  ctx.restore();

  // Character cards
  const cardW  = 120;
  const cardH  = 110;
  const gap    = 16;
  const totalW = CHARACTERS.length * cardW + (CHARACTERS.length - 1) * gap;
  const startX = (LOGICAL_W - totalW) / 2;
  const cardY  = 170;

  for (let i = 0; i < CHARACTERS.length; i++) {
    const cx  = startX + i * (cardW + gap);
    const sel = i === selectedCharIdx;

    ctx.save();
    ctx.fillStyle   = sel ? 'rgba(30,80,180,0.6)' : 'rgba(255,255,255,0.05)';
    ctx.strokeStyle = sel ? '#44aaff' : 'rgba(255,255,255,0.2)';
    ctx.lineWidth   = sel ? 3 : 1;
    roundRect(cx, cardY, cardW, cardH, 12);
    ctx.fill();
    ctx.stroke();

    ctx.font         = '46px serif';
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle    = '#fff';
    ctx.fillText(CHARACTERS[i].emoji, cx + cardW / 2, cardY + 42);

    ctx.font         = '12px Arial';
    ctx.textBaseline = 'top';
    ctx.fillStyle    = sel ? '#aaddff' : '#8899aa';
    ctx.fillText(CHARACTERS[i].name, cx + cardW / 2, cardY + 82);
    ctx.restore();

    registerButton(`char-${i}`, cx, cardY, cardW, cardH);
  }

  drawButton('start',   'התחל',        LOGICAL_W / 2 - 168, 312, 150, 50, '#1a6aff');
  drawButton('history', 'היסטוריה 📊', LOGICAL_W / 2 + 18,  312, 150, 50, '#2a5a2a');

  ctx.save();
  ctx.font      = '13px Arial';
  ctx.fillStyle = 'rgba(150,170,210,0.7)';
  ctx.textAlign = 'center';
  ctx.fillText('חצים: תנועה | רווח: קפיצה', LOGICAL_W / 2, 370);

  ctx.font      = '12px Arial';
  ctx.fillStyle = 'rgba(180,200,230,0.5)';
  ctx.fillText('נבנה על ידי בועז אברמוביץ', LOGICAL_W / 2, 388);
  ctx.restore();
}

function drawLevelCompleteScreen() {
  drawBackground();
  drawGround();

  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.fillRect(0, 0, LOGICAL_W, LOGICAL_H);

  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle    = '#44ffaa';
  ctx.font         = 'bold 48px Arial';
  ctx.shadowColor  = '#00ff88';
  ctx.shadowBlur   = 20;
  ctx.fillText('שלב הושלם!', LOGICAL_W / 2, 115);
  ctx.shadowBlur   = 0;

  // New record banner
  if (isNewRecord) {
    ctx.fillStyle  = '#ffdd00';
    ctx.font       = 'bold 22px Arial';
    ctx.shadowColor = '#ff8800';
    ctx.shadowBlur  = 12;
    ctx.fillText('🏆 שיא חדש!', LOGICAL_W / 2, 158);
    ctx.shadowBlur  = 0;
  }

  ctx.fillStyle = '#ffffff';
  ctx.font      = '22px Arial';
  ctx.fillText(`ניקוד: ${score}`, LOGICAL_W / 2, isNewRecord ? 195 : 175);

  const prevRecord = loadRecords()[`level${currentLevel}`];
  if (prevRecord && !isNewRecord) {
    ctx.fillStyle = '#aaaaaa';
    ctx.font      = '14px Arial';
    ctx.fillText(`שיא קודם: ${prevRecord.score}  (${prevRecord.date})`, LOGICAL_W / 2, 220);
  }

  ctx.fillStyle = '#aaddff';
  ctx.font      = '15px Arial';
  ctx.fillText(`שלב ${currentLevel + 2} - הכן את עצמך!`, LOGICAL_W / 2, 248);

  drawButton('next-level', 'שלב הבא', LOGICAL_W / 2 - 80, 272, 160, 50);
  ctx.restore();

  // Confetti on top of everything
  drawConfetti();
}

function drawGameOverScreen() {
  drawBackground();
  drawGround();

  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.6)';
  ctx.fillRect(0, 0, LOGICAL_W, LOGICAL_H);

  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle    = '#ff4444';
  ctx.font         = 'bold 48px Arial';
  ctx.shadowColor  = '#ff0000';
  ctx.shadowBlur   = 20;
  ctx.fillText('המשחק נגמר', LOGICAL_W / 2, 130);
  ctx.shadowBlur   = 0;

  ctx.fillStyle = '#cccccc';
  ctx.font      = '20px Arial';
  ctx.fillText(`שלב ${currentLevel + 1}  |  ניקוד: ${score}`, LOGICAL_W / 2, 195);

  drawButton('try-again', 'נסה שוב', LOGICAL_W / 2 - 80, 240, 160, 50, '#aa2222');
  ctx.restore();
}

function drawVictoryScreen() {
  drawBackground();

  ctx.save();
  ctx.fillStyle = 'rgba(0,0,20,0.5)';
  ctx.fillRect(0, 0, LOGICAL_W, LOGICAL_H);

  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle    = '#ffdd00';
  ctx.font         = 'bold 56px Arial';
  ctx.shadowColor  = '#ffaa00';
  ctx.shadowBlur   = 30;
  ctx.fillText('ניצחת!', LOGICAL_W / 2, 100);
  ctx.shadowBlur   = 0;

  ctx.fillStyle = '#aaffdd';
  ctx.font      = '22px Arial';
  ctx.fillText('השלמת את כל 10 השלבים!', LOGICAL_W / 2, 158);

  ctx.fillStyle = '#ffffff';
  ctx.font      = '22px Arial';
  ctx.fillText(`ניקוד סופי: ${score}`, LOGICAL_W / 2, 200);

  ctx.font = '60px serif';
  ctx.fillText('🏆', LOGICAL_W / 2, 270);

  drawButton('restart', 'שחק שוב', LOGICAL_W / 2 - 80, 320, 160, 50, '#886600');
  ctx.restore();

  drawConfetti();
}

function drawHistoryScreen() {
  drawBackground();

  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.6)';
  ctx.fillRect(0, 0, LOGICAL_W, LOGICAL_H);

  // Title
  ctx.textAlign    = 'center';
  ctx.textBaseline = 'middle';
  ctx.font         = 'bold 32px Arial';
  ctx.fillStyle    = '#aaddff';
  ctx.fillText('📊 היסטוריית שיאים', LOGICAL_W / 2, 32);

  const records = loadRecords();
  const hasAny  = Object.keys(records).length > 0;

  if (!hasAny) {
    ctx.font      = '20px Arial';
    ctx.fillStyle = '#888899';
    ctx.fillText('עדיין אין שיאים. שחק כדי לרשום!', LOGICAL_W / 2, LOGICAL_H / 2);
  } else {
    // Table header
    const tableX = 80;
    const tableW = LOGICAL_W - 160;
    const rowH   = 30;
    const startY = 65;

    ctx.fillStyle = 'rgba(255,255,255,0.07)';
    ctx.fillRect(tableX, startY, tableW, rowH);

    ctx.font         = 'bold 14px Arial';
    ctx.fillStyle    = '#aaddff';
    ctx.textAlign    = 'right';
    ctx.textBaseline = 'middle';
    const midY = startY + rowH / 2;
    ctx.fillText('שלב',    tableX + tableW - 20,       midY);
    ctx.fillText('שיא',    tableX + tableW - 130,      midY);
    ctx.fillText('תאריך',  tableX + tableW - 260,      midY);
    ctx.fillText('כוכבים', tableX + tableW - 390,      midY);

    // Rows
    for (let i = 0; i < LEVELS.length; i++) {
      const key  = `level${i}`;
      const rec  = records[key];
      const ry   = startY + rowH + i * rowH;

      // Alternating row bg
      ctx.fillStyle = i % 2 === 0 ? 'rgba(255,255,255,0.03)' : 'rgba(0,0,0,0.2)';
      ctx.fillRect(tableX, ry, tableW, rowH);

      const cy = ry + rowH / 2;

      if (rec) {
        // Stars: 1 star per 10 points, max 5
        const stars = '⭐'.repeat(Math.min(5, Math.max(1, Math.floor(rec.score / 5))));

        ctx.font      = '14px Arial';
        ctx.fillStyle = '#ffffff';
        ctx.textAlign = 'right';
        ctx.fillText(`${i + 1}`,      tableX + tableW - 20,  cy);
        ctx.fillStyle = '#ffdd44';
        ctx.fillText(`${rec.score}`,  tableX + tableW - 130, cy);
        ctx.fillStyle = '#aaaaaa';
        ctx.fillText(rec.date,        tableX + tableW - 260, cy);
        ctx.font      = '12px serif';
        ctx.fillStyle = '#ffdd44';
        ctx.fillText(stars,           tableX + tableW - 390, cy);
      } else {
        ctx.font      = '13px Arial';
        ctx.fillStyle = '#555566';
        ctx.textAlign = 'right';
        ctx.fillText(`${i + 1}`,  tableX + tableW - 20,  cy);
        ctx.fillText('---',        tableX + tableW - 130, cy);
        ctx.fillText('---',        tableX + tableW - 260, cy);
      }
    }
  }

  drawButton('back-to-start', '← חזור', 30, 10, 110, 36, '#333355');
  ctx.restore();
}

// ============================================================
// SECTION 20 - MAIN LOOP
// ============================================================

function gameLoop(timestamp) {
  const dt = Math.min((timestamp - lastTimestamp) / 1000, 0.1);
  lastTimestamp = timestamp;

  uiButtons = []; // reset click registry each frame

  update(dt);

  ctx.clearRect(0, 0, LOGICAL_W, LOGICAL_H);

  switch (gameState) {
    case STATE.START:
      drawStartScreen();
      break;
    case STATE.PLAYING:
      drawBackground();
      drawGround();
      drawMeteors();
      drawPlayer();
      drawHUD();
      break;
    case STATE.LEVEL_COMPLETE:
      drawLevelCompleteScreen();
      break;
    case STATE.GAME_OVER:
      drawGameOverScreen();
      break;
    case STATE.VICTORY:
      drawVictoryScreen();
      break;
    case STATE.HISTORY:
      drawHistoryScreen();
      break;
  }

  requestAnimationFrame(gameLoop);
}

// Start the loop on the next animation frame
requestAnimationFrame((ts) => {
  lastTimestamp = ts;
  requestAnimationFrame(gameLoop);
});

// ============================================================
// SECTION 21 - FULLSCREEN
// ============================================================
// Entering fullscreen also requests landscape orientation on mobile,
// so players don't need to rotate the phone manually.

// Wire mute button
document.getElementById('btn-mute').addEventListener('click', toggleMute);
updateMuteButton(); // set correct icon from saved preference on load

const btnFS = document.getElementById('btn-fullscreen');

function enterFullscreen() {
  const el  = document.documentElement;
  const req = el.requestFullscreen || el.webkitRequestFullscreen || el.mozRequestFullScreen;
  if (req) {
    req.call(el).then(() => {
      // Lock to landscape after fullscreen is granted (Android Chrome)
      if (screen.orientation && screen.orientation.lock) {
        screen.orientation.lock('landscape').catch(() => {});
      }
      resizeCanvas();
    }).catch(() => {
      // Fullscreen API rejected (common on iOS Safari) - use scroll trick
      // to hide the address bar as a fallback
      window.scrollTo(0, 1);
      resizeCanvas();
    });
  } else {
    // No fullscreen API at all (older iOS) - scroll fallback
    window.scrollTo(0, 1);
    resizeCanvas();
  }
}

function exitFullscreen() {
  const ex = document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen;
  if (ex) ex.call(document);
}

function isFullscreen() {
  return !!(document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement);
}

function updateFSButton() {
  btnFS.textContent = isFullscreen() ? '✕' : '⛶';
  btnFS.title = isFullscreen() ? 'יציאה ממסך מלא' : 'מסך מלא';
}

btnFS.addEventListener('click', () => {
  isFullscreen() ? exitFullscreen() : enterFullscreen();
});

document.addEventListener('fullscreenchange',       updateFSButton);
document.addEventListener('webkitfullscreenchange', updateFSButton);
document.addEventListener('mozfullscreenchange',    updateFSButton);

// Also resize canvas when fullscreen changes
document.addEventListener('fullscreenchange',       resizeCanvas);
document.addEventListener('webkitfullscreenchange', resizeCanvas);
