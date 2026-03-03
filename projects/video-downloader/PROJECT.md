# FETCH — Media Downloader UI

## Project Overview

A professional media downloader UI built for the **Energidi** platform. Allows users to analyze video/audio URLs from multiple platforms, select quality and format options aligned to the actual source resolutions, and download or queue media files.

---

## Status

`IN PROGRESS` — UI prototype v5 complete. Backend integration pending.

---

## Stack

| Layer        | Technology                          |
|--------------|-------------------------------------|
| UI           | HTML5 + CSS3 + Vanilla JavaScript   |
| Fonts        | Syne (UI), Space Mono (data/mono)   |
| Engine       | Energidi v2.1.4                     |
| Backend (TBD)| Python + yt-dlp + FFmpeg            |
| Packaging    | PyInstaller (planned)               |

---

## Features Completed

- [x] 2-column layout — Preview / Config (queue removed in v5)
- [x] Sticky topbar with nav and status pill
- [x] URL input bar with shake animation on empty submit
- [x] Analyze button with 2-phase loading (preview → formats)
- [x] Skeleton shimmer loader for resolution grid
- [x] Dynamic resolution grid — only shows resolutions available from the source
- [x] Unavailable resolutions shown as disabled/dashed with tooltip
- [x] Resolution legend (Available / Not in source)
- [x] Codec badge per resolution button (AV1, H.264, etc.)
- [x] Download mode tabs — Video + Audio / Audio Only / Clip / Trim
- [x] Clip mode — highlights Time Range card with blue glow + pulsing ACTIVE badge
- [x] Video editor trimmer — draggable start/end handles over thumbnail strip with live timecodes and ruler
- [x] Format chips — dynamic per mode (video vs audio formats)
- [x] Output section — folder path, filename, toggles (Metadata / Subtitles / Thumbnail / Chapters)
- [x] Toggle tooltips — each option explained inline via hover
- [x] Download action bar — real-time size + label updates on selection change
- [x] Live progress card — speed, ETA, downloaded, total
- [x] Progress completes with green success state
- [x] "Powered by Energidi" branded footer with session counter, engine version, source count
- [x] Improved text contrast throughout (muted colors legible on dark background)
- [x] Responsive breakpoints (1100px, 900px)

---

## Demo Sources (Simulated)

| Platform     | Max Resolution | Notes                        |
|--------------|---------------|------------------------------|
| YouTube      | 4K (2160p)    | All 5 resolutions available  |
| Vimeo        | 1080p         | 4K and 360p unavailable      |
| Twitter / X  | 720p          | Capped by platform           |
| SoundCloud   | Audio only    | Forces Audio Only mode       |

---

## Pending / Next Steps

- [ ] Python backend integration (yt-dlp `extract_info()` → real format list)
- [ ] Real URL parsing and platform detection
- [ ] FFmpeg post-processing (merge streams, trim clips)
- [ ] Settings page (theme, default path, concurrent downloads)
- [ ] History tab with persistent log
- [ ] Actual queue processing with concurrency control
- [ ] Error states (geo-blocked, private video, rate limit)
- [ ] PyInstaller packaging for Windows distribution

---

## File Reference

| File                  | Description                              |
|-----------------------|------------------------------------------|
| `downloader_v5.html`  | Latest UI build (current)                |
| `downloader_v4.html`  | 3-col layout with queue + storage        |
| `downloader_v3.html`  | Previous iteration (3-col layout)        |

---

## Key Decisions

- **Resolution grid is data-driven** — maps 1:1 to yt-dlp's `formats` array in the real backend.
- **"Powered by Energidi"** in footer and status pill — all yt-dlp branding replaced.
- **Clip mode** activates the Time Range section visually to guide user attention.
- **Video editor trimmer** replaces plain text inputs — draggable handles over a thumbnail strip with live timecodes.
- **Two-phase analyze** — preview loads first (~350ms), then format probe completes (~1.3s), mimicking real network latency.
- **Queue and Storage removed in v5** — simplified to focus on single-download flow.

---

## Notes

- Fonts loaded from Google Fonts CDN — requires internet for correct rendering.
- All colors use CSS custom properties for easy theming.
- No framework dependencies — ships as a single `.html` file.

---

*Last updated: March 2026*
