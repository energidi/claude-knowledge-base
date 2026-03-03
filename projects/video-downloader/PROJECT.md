# FETCH — Media Downloader UI

## Project Overview

A professional media downloader built for the **Energidi** platform. Allows users to analyze video/audio URLs from multiple platforms, select quality and format options aligned to the actual source resolutions, and download or queue media files.

---

## Status

`IN PROGRESS` — UI v5 + Python backend complete. PyInstaller packaging pending.

---

## Stack

| Layer      | Technology                        |
|------------|-----------------------------------|
| UI         | HTML5 + CSS3 + Vanilla JavaScript |
| Fonts      | Syne (UI), Space Mono (data/mono) |
| Engine     | Energidi v2.1.4                   |
| Backend    | Python + FastAPI + uvicorn        |
| Downloader | yt-dlp                            |
| Processing | FFmpeg                            |
| Packaging  | PyInstaller (planned)             |

---

## Architecture

```
[downloader_v5.html]
      ↕ fetch / EventSource (localhost:8765)
[FastAPI — server.py]
      ↕
[downloader.py — yt-dlp + FFmpeg]
      ↕
[main.py — entry point, auto-opens browser]
```

Server binds to `127.0.0.1` only. Never exposed to the network.

---

## API Endpoints

| Method | Route            | Description                                     |
|--------|------------------|-------------------------------------------------|
| GET    | `/health`        | Server status check                             |
| POST   | `/analyze`       | Extract metadata + format list from URL         |
| POST   | `/download`      | Start download in background thread, returns ID |
| GET    | `/progress/{id}` | SSE stream — real-time speed, ETA, percent      |
| POST   | `/cancel/{id}`   | Cancel active download by ID                    |

---

## Features Completed

**UI**
- [x] 2-column layout — Preview / Config (queue removed in v5)
- [x] Sticky topbar with nav and Energidi status pill
- [x] URL input bar with shake animation on empty submit
- [x] Analyze button — calls real `/analyze` endpoint (previously 2-phase mock)
- [x] Skeleton shimmer loader during analysis
- [x] Dynamic resolution grid — availability driven by yt-dlp format list
- [x] Unavailable resolutions shown as disabled/dashed with tooltip
- [x] Resolution legend (Available / Not in source)
- [x] Codec badge per resolution button (AV1, H.264, VP9, H.265)
- [x] Download mode tabs — Video + Audio / Audio Only / Clip / Trim
- [x] Clip mode — highlights Time Range card with blue glow + pulsing ACTIVE badge
- [x] Video editor trimmer — draggable start/end handles over thumbnail strip with live timecodes and ruler
- [x] Format chips — dynamic per mode (video vs audio formats)
- [x] Output section — folder path, filename, toggles (Metadata / Subtitles / Thumbnail / Chapters)
- [x] Toggle tooltips — each option explained inline via hover
- [x] Download action bar — real-time label updates on selection change
- [x] Live progress card — speed, ETA, downloaded, total (fed by SSE stream)
- [x] Progress completes with green success state
- [x] Error banner for failed analyze or download
- [x] "Powered by Energidi" branded footer with session counter, engine version, source count
- [x] Improved text contrast throughout (muted colors legible on dark background)
- [x] Responsive breakpoints (1100px, 900px)

**Backend**
- [x] `downloader.py` — yt-dlp wrapper: analyze, format mapping, download, progress hooks, cancel
- [x] `server.py` — FastAPI app with all 5 routes + SSE streaming
- [x] `main.py` — entry point: finds free port, opens browser, starts uvicorn
- [x] `requirements.txt` — pinned dependencies
- [x] `build.spec` — PyInstaller config for single-file `FETCH.exe`
- [x] Real platform detection from URL
- [x] Real resolution + codec extraction from yt-dlp `formats` array
- [x] Audio-only detection (e.g. SoundCloud forces Audio Only mode)
- [x] Format selector builder for yt-dlp (best, by height, audio-only)
- [x] FFmpeg post-processing: container conversion, audio extraction, metadata embed, thumbnail embed
- [x] Clip/trim via yt-dlp `download_ranges` + `force_keyframes_at_cuts`
- [x] Thread-safe download registry with per-ID progress state

---

## Demo Sources (Simulated — pre-backend)

| Platform    | Max Resolution | Notes                       |
|-------------|---------------|-----------------------------|
| YouTube     | 4K (2160p)    | All 5 resolutions available |
| Vimeo       | 1080p         | 4K and 360p unavailable     |
| Twitter / X | 720p          | Capped by platform          |
| SoundCloud  | Audio only    | Forces Audio Only mode      |

---

## Pending / Next Steps

- [ ] Settings page (theme, default output path, concurrent downloads)
- [ ] History tab with persistent download log
- [ ] Concurrent queue processing with concurrency control
- [ ] Error states for geo-blocked, private, and rate-limited videos
- [ ] PyInstaller packaging for Windows distribution (`FETCH.exe`)

---

## File Reference

| File                 | Description                                      |
|----------------------|--------------------------------------------------|
| `downloader_v5.html` | Latest UI build — wired to real backend (current)|
| `downloader.py`      | yt-dlp + FFmpeg wrapper, all download logic      |
| `server.py`          | FastAPI server, all HTTP routes + SSE            |
| `main.py`            | Entry point — starts server, opens browser       |
| `requirements.txt`   | Python dependencies                              |
| `build.spec`         | PyInstaller config for FETCH.exe                 |
| `downloader_v4.html` | 3-col layout with queue + storage                |
| `downloader_v3.html` | Previous iteration (3-col layout)               |

---

## Key Decisions

- **Resolution grid is data-driven** — maps 1:1 to yt-dlp's `formats` array. No hardcoded resolutions.
- **"Powered by Energidi"** in footer and status pill — all yt-dlp branding replaced.
- **FastAPI + SSE** for progress streaming — no polling, no WebSockets needed.
- **Server binds to 127.0.0.1 only** — never accessible from outside the machine.
- **Clip mode** activates the Time Range section visually to guide user attention.
- **Video editor trimmer** replaces plain text inputs — draggable handles over a thumbnail strip with live timecodes.
- **Queue and Storage removed in v5** — simplified to focus on single-download flow.
- **No framework dependencies** — UI ships as a single `.html` file.

---

## Quick Start

```bash
# Install dependencies
pip install -r requirements.txt

# Install FFmpeg and add to PATH
# Windows: https://ffmpeg.org/download.html

# Run
python main.py
# Browser opens automatically at http://127.0.0.1:8765/ui/downloader_v5.html
```

---

## Notes

- Fonts loaded from Google Fonts CDN — requires internet for correct rendering.
- All colors use CSS custom properties for easy theming.
- `console=True` in `build.spec` — set to `False` to hide terminal window in release build.

---

*Last updated: March 2026*
