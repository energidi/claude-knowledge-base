"""
downloader.py - Energidi / FETCH
yt-dlp + FFmpeg wrapper. All media logic isolated here.
"""

import re
import uuid
import threading
from pathlib import Path
from typing import Optional
import yt_dlp


# ── Helpers ───────────────────────────────────────────────────────────────────

def _secs_to_tc(secs: float) -> str:
    s = int(max(0, secs))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h:02d}:{m:02d}:{sec:02d}"
    return f"{m:02d}:{sec:02d}"


def _format_bytes(b: Optional[int]) -> str:
    if not b:
        return "—"
    for unit in ("B", "KB", "MB", "GB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} TB"


def _map_platform(url: str) -> str:
    mapping = {
        "youtube.com": "YouTube", "youtu.be": "YouTube",
        "vimeo.com": "Vimeo",
        "twitter.com": "Twitter / X", "x.com": "Twitter / X",
        "soundcloud.com": "SoundCloud",
        "tiktok.com": "TikTok",
        "twitch.tv": "Twitch",
        "dailymotion.com": "Dailymotion",
        "reddit.com": "Reddit",
        "instagram.com": "Instagram",
        "facebook.com": "Facebook",
    }
    for domain, name in mapping.items():
        if domain in url:
            return name
    return "Unknown"


def _codec_label(vcodec: str) -> str:
    if not vcodec or vcodec == "none":
        return ""
    vc = vcodec.lower()
    if "av01" in vc or "av1" in vc:
        return "AV1"
    if "avc" in vc or "h264" in vc or "x264" in vc:
        return "H.264"
    if "vp9" in vc:
        return "VP9"
    if "hevc" in vc or "h265" in vc:
        return "H.265"
    return ""


# ── Analyze ───────────────────────────────────────────────────────────────────

RESOLUTION_BUCKETS = [
    ("4K",  "2160p", 2160),
    ("FHD", "1080p", 1080),
    ("HD",  "720p",  720),
    ("SD",  "480p",  480),
    ("360", "360p",  360),
]

PREFERRED_VIDEO = ["MP4", "MKV", "WEBM"]
PREFERRED_AUDIO = ["MP3", "AAC", "FLAC", "OGG", "OPUS", "WAV", "M4A"]


def analyze(url: str) -> dict:
    """Extract metadata and format list from URL. Returns UI-ready dict."""
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

    formats = info.get("formats") or []
    available_heights: set[int] = set()
    found_video_exts: set[str] = set()
    found_audio_exts: set[str] = set()
    is_audio_only = True

    # Codec per height — best quality codec wins
    codec_per_height: dict[int, str] = {}

    for f in formats:
        h       = f.get("height")
        vcodec  = f.get("vcodec", "none")
        acodec  = f.get("acodec", "none")
        ext     = (f.get("ext") or "").upper()

        if vcodec and vcodec != "none" and h:
            available_heights.add(h)
            is_audio_only = False
            if ext:
                found_video_exts.add(ext)
            label = _codec_label(vcodec)
            if label and h not in codec_per_height:
                codec_per_height[h] = label

        if acodec and acodec != "none" and ext:
            found_audio_exts.add(ext)

    # Normalise to preferred containers
    video_formats = [f for f in PREFERRED_VIDEO if f in found_video_exts]
    if not video_formats and not is_audio_only:
        video_formats = ["MP4"]

    audio_formats = [f for f in PREFERRED_AUDIO if f in found_audio_exts]
    if not audio_formats:
        audio_formats = ["MP3", "AAC"]

    # Build resolution availability list
    def best_codec_for(target_h: int) -> str:
        for h, codec in codec_per_height.items():
            if abs(h - target_h) <= 60:
                return codec
        return ""

    available_res = []
    for label, sub, target_h in RESOLUTION_BUCKETS:
        avail = any(abs(h - target_h) <= 60 for h in available_heights)
        available_res.append({
            "label": label,
            "sub": sub,
            "codec": best_codec_for(target_h) if avail else "",
            "available": avail,
        })

    # Duration
    duration_sec = int(info.get("duration") or 0)

    # Views
    views = info.get("view_count")
    if views and views >= 1_000_000:
        views_str = f"{views / 1_000_000:.1f}M"
    elif views and views >= 1_000:
        views_str = f"{views / 1_000:.0f}K"
    elif views:
        views_str = f"{views:,}"
    else:
        views_str = "—"

    # Upload date
    raw_date = info.get("upload_date") or ""
    try:
        from datetime import datetime
        date_str = datetime.strptime(raw_date, "%Y%m%d").strftime("%b %Y")
    except Exception:
        date_str = raw_date or "—"

    # Platform
    platform = _map_platform(url)
    plat_abbr = "".join(w[0].upper() for w in platform.replace("/", "").split()[:2])[:2]

    return {
        "title":        info.get("title") or "Untitled",
        "channel":      info.get("uploader") or info.get("channel") or "—",
        "views":        views_str,
        "date":         date_str,
        "duration":     _secs_to_tc(duration_sec),
        "duration_sec": duration_sec,
        "thumbnail":    info.get("thumbnail") or "",
        "platform":     platform,
        "plat_abbr":    plat_abbr,
        "plat_sub":     info.get("webpage_url_domain") or url,
        "available_res": available_res,
        "video_formats": video_formats,
        "audio_formats": audio_formats,
        "audio_only":    is_audio_only,
    }


# ── Frame extraction ──────────────────────────────────────────────────────────

def _pick_stream_url(info: dict) -> Optional[str]:
    """Return a direct video stream URL from yt-dlp info dict."""
    if info.get("url"):
        return info["url"]
    for f in reversed(info.get("formats") or []):
        if f.get("vcodec") not in (None, "none") and f.get("url"):
            return f["url"]
    return None


def extract_frames(url: str, count: int = 8) -> list:
    """Extract evenly-spaced preview frames. Returns list of base64 JPEG data URIs."""
    import subprocess, base64, tempfile, shutil as _shutil
    from concurrent.futures import ThreadPoolExecutor, as_completed

    if _shutil.which("ffmpeg") is None:
        return []

    ydl_opts = {
        "quiet": True, "no_warnings": True, "skip_download": True, "noplaylist": True,
        "format": "best[height<=480][ext=mp4]/best[height<=480]/best",
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

    duration = float(info.get("duration") or 0)
    if duration < 1:
        return []

    stream_url = _pick_stream_url(info)
    if not stream_url:
        return []

    tmp_dir = Path(tempfile.mkdtemp(prefix="fetch_frames_"))

    def _one(i: int, t: float) -> tuple:
        out = tmp_dir / f"f{i:02d}.jpg"
        try:
            subprocess.run(
                ["ffmpeg", "-ss", f"{t:.2f}", "-i", stream_url,
                 "-frames:v", "1", "-vf", "scale=160:-1",
                 "-q:v", "5", str(out), "-y", "-hide_banner", "-loglevel", "error"],
                timeout=15, check=False,
            )
            if out.exists():
                return i, "data:image/jpeg;base64," + base64.b64encode(out.read_bytes()).decode()
        except Exception:
            pass
        return i, ""

    timestamps = [duration * (i + 0.5) / count for i in range(count)]
    results = [""] * count
    try:
        with ThreadPoolExecutor(max_workers=4) as ex:
            futures = {ex.submit(_one, i, t): i for i, t in enumerate(timestamps)}
            for fut in as_completed(futures):
                idx, data = fut.result()
                results[idx] = data
    finally:
        _shutil.rmtree(tmp_dir, ignore_errors=True)

    return results


# ── Download registry ─────────────────────────────────────────────────────────

_downloads: dict[str, dict] = {}


def _update(dl_id: str, **kwargs) -> None:
    if dl_id in _downloads:
        _downloads[dl_id].update(kwargs)


# ── Format selector ───────────────────────────────────────────────────────────

def _build_format(mode: str, resolution: str) -> str:
    if mode == "audio":
        return "bestaudio/best"
    res_map = {"2160p": 2160, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360}
    h = res_map.get(resolution)
    if not h:
        # Pre-muxed mp4 (already contains video+audio in one file, no merge needed)
        # Falls back to separate streams only if no pre-muxed format exists
        return "best[ext=mp4]/best[ext=webm]/best"
    return (
        f"bestvideo[ext=mp4][height<={h}]+bestaudio[ext=m4a]"
        f"/bestvideo[height<={h}]+bestaudio"
        f"/best[height<={h}]"
        f"/best"
    )


def _tc_to_secs(tc: str) -> Optional[float]:
    tc = tc.strip()
    if not tc:
        return None
    parts = tc.split(":")
    try:
        parts = [float(p) for p in parts]
        if len(parts) == 2:
            return parts[0] * 60 + parts[1]
        if len(parts) == 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
    except ValueError:
        pass
    return None


# ── Start download ────────────────────────────────────────────────────────────

def start_download(
    url: str,
    output_dir: str,
    filename: str,
    mode: str,
    resolution: str,
    fmt: str,
    start_tc: str = "",
    end_tc: str = "",
    metadata: bool = False,
    subtitles: bool = False,
    thumbnail: bool = False,
    chapters: bool = False,
) -> str:
    dl_id = uuid.uuid4().hex[:12]
    _downloads[dl_id] = {
        "status": "starting", "speed": "—", "eta": "—",
        "downloaded": "—", "total": "—", "percent": 0.0, "error": None,
    }
    t = threading.Thread(
        target=_run,
        args=(dl_id, url, output_dir, filename, mode, resolution, fmt,
              start_tc, end_tc, metadata, subtitles, thumbnail, chapters),
        daemon=True,
    )
    t.start()
    return dl_id


def _run(
    dl_id, url, output_dir, filename, mode, resolution, fmt,
    start_tc, end_tc, metadata, subtitles, thumbnail, chapters,
):
    """
    Downloads via yt-dlp subprocess into a private temp dir.
    After yt-dlp exits, moves ONLY the final media file to output_dir.
    This is the only reliable way to prevent fragment files (.m4a, .webm, .vtt)
    from appearing in the user's folder — yt-dlp always creates them during merge
    and there is no API hook that fires at exactly the right moment to delete them.
    """
    import subprocess, sys, tempfile, shutil, json as _json

    tmp_dir = None
    try:
        # FFmpeg is required to merge separate video+audio streams.
        # Without it, high-resolution downloads produce video-only files with no audio.
        if shutil.which("ffmpeg") is None:
            _update(dl_id, status="error", error=(
                "FFmpeg is not installed or not on PATH. "
                "Download it from https://ffmpeg.org/download.html and add it to PATH, "
                "then restart FETCH."
            ))
            return

        out_path = Path(output_dir)
        out_path.mkdir(parents=True, exist_ok=True)

        # All yt-dlp output (fragments, intermediates, final file) goes here.
        # We delete this entire dir at the end.
        tmp_dir = Path(tempfile.mkdtemp(prefix="fetch_dl_"))

        if filename.strip():
            safe    = re.sub(r'[<>:"/\\|?*]', "-", filename.strip())
            outtmpl = str(tmp_dir / f"{safe}.%(ext)s")
        else:
            outtmpl = str(tmp_dir / "%(title)s.%(ext)s")

        # ── Determine expected final extension ────────────────────────────────
        if mode == "audio":
            codec_map = {
                "MP3": "mp3", "AAC": "aac", "FLAC": "flac",
                "OGG": "ogg", "OPUS": "opus", "WAV": "wav", "M4A": "m4a",
            }
            final_ext = codec_map.get(fmt.upper(), "mp3")
        else:
            final_ext = fmt.lower()  # mp4, mkv, webm

        # ── Build CLI command ─────────────────────────────────────────────────
        cmd = [
            sys.executable, "-m", "yt_dlp",
            "--no-playlist",
            "--no-warnings",
            "--newline",
            "--progress-template", "%(progress)j",
            "-o", outtmpl,
            "-f", _build_format(mode, resolution),
        ]

        if mode == "audio":
            cmd += ["-x", "--audio-format", final_ext, "--audio-quality", "0"]
        else:
            cmd += ["--merge-output-format", final_ext]

        if metadata:
            cmd += ["--add-metadata"]
        if thumbnail:
            cmd += ["--embed-thumbnail"]
        start_secs = _tc_to_secs(start_tc)
        end_secs   = _tc_to_secs(end_tc)
        if start_secs is not None or end_secs is not None:
            s = start_secs or 0.0
            e = end_secs
            section = f"*{s}-{e}" if e else f"*{s}-inf"
            cmd += ["--download-sections", section, "--force-keyframes-at-cuts"]

        cmd.append(url)

        # ── Stream progress from stdout ───────────────────────────────────────
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                p = _json.loads(line)
                status = p.get("status", "")
                if status == "downloading":
                    dl  = p.get("downloaded_bytes") or 0
                    tot = p.get("total_bytes") or p.get("total_bytes_estimate") or 0
                    pct = round((dl / tot) * 100, 1) if tot > 0 else 0.0
                    spd = p.get("speed") or 0
                    eta = p.get("eta") or 0
                    spd_str = (_format_bytes(int(spd)) + "/s") if spd else "—"
                    eta_str = f"{int(eta)//60}:{int(eta)%60:02d}" if eta else "—"
                    _update(dl_id,
                        status="downloading", percent=pct,
                        speed=spd_str, eta=eta_str,
                        downloaded=_format_bytes(dl),
                        total=_format_bytes(tot) if tot else "—",
                    )
                elif status == "finished":
                    _update(dl_id, status="processing", percent=99.0, speed="—", eta="—")
            except (_json.JSONDecodeError, ValueError):
                pass

        proc.wait()

        if proc.returncode not in (0, 1):
            _update(dl_id, status="error", error=f"yt-dlp exited with code {proc.returncode}")
            return

        # ── Move ONLY the final media file to output_dir ─────────────────────
        # yt-dlp is fully done. tmp_dir may contain: final.mp4, final.f137.mp4,
        # final.f140.m4a, final.webm, etc. We want only the largest file with
        # the expected extension — that is always the merged output.
        candidates = sorted(
            [f for f in tmp_dir.iterdir() if f.suffix.lstrip(".") == final_ext],
            key=lambda f: f.stat().st_size,
            reverse=True,
        )

        if not candidates:
            # Fallback: take the largest file in tmp_dir regardless of extension
            candidates = sorted(
                list(tmp_dir.iterdir()),
                key=lambda f: f.stat().st_size,
                reverse=True,
            )

        if not candidates:
            _update(dl_id, status="error", error="Download produced no output file.")
            return

        final_file = candidates[0]
        dest = out_path / final_file.name
        shutil.move(str(final_file), str(dest))

        _update(dl_id, status="done", percent=100.0, speed="—", eta="Done")

    except Exception as e:
        _update(dl_id, status="error", error=f"Unexpected error: {str(e)[:300]}")
    finally:
        # Always nuke the temp dir — takes all fragments with it
        if tmp_dir and tmp_dir.exists():
            try:
                shutil.rmtree(tmp_dir)
            except Exception:
                pass


def cancel_download(dl_id: str) -> bool:
    if dl_id not in _downloads:
        return False
    _update(dl_id, status="cancelled")
    return True


def get_progress(dl_id: str) -> Optional[dict]:
    return _downloads.get(dl_id)
