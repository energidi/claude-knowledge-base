"""
server.py - Energidi / FETCH
FastAPI backend. Binds to 127.0.0.1 only.
"""

import asyncio
import json
from pathlib import Path
from typing import AsyncGenerator

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, field_validator

import downloader

app = FastAPI(title="FETCH / Energidi", version="2.1.4", docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # safe — server only binds to 127.0.0.1
    allow_methods=["*"],
    allow_headers=["*"],
)

_ui_dir = Path(__file__).parent
app.mount("/ui", StaticFiles(directory=str(_ui_dir), html=True), name="ui")


# ── Models ────────────────────────────────────────────────────────────────────

class AnalyzeRequest(BaseModel):
    url: str

    @field_validator("url")
    @classmethod
    def validate_url(cls, v: str) -> str:
        v = v.strip()
        if not v.startswith(("http://", "https://")):
            raise ValueError("URL must start with http:// or https://")
        return v


class DownloadRequest(BaseModel):
    url: str
    output_dir: str = str(Path.home() / "Downloads" / "FETCH")
    filename: str = ""
    mode: str = "video"
    resolution: str = "best"
    fmt: str = "MP4"
    start_tc: str = ""
    end_tc: str = ""
    metadata: bool = False
    subtitles: bool = False
    thumbnail: bool = False
    chapters: bool = False

    @field_validator("mode")
    @classmethod
    def validate_mode(cls, v: str) -> str:
        if v not in ("video", "audio", "clip"):
            raise ValueError("mode must be video, audio, or clip")
        return v

    @field_validator("url")
    @classmethod
    def validate_url(cls, v: str) -> str:
        v = v.strip()
        if not v.startswith(("http://", "https://")):
            raise ValueError("URL must start with http:// or https://")
        return v


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "engine": "Energidi v2.1.4"}


@app.get("/config")
def config():
    """Returns machine-specific defaults for the UI."""
    downloads = Path.home() / "Downloads" / "FETCH"
    return {
        "default_output_dir": str(downloads),
    }


@app.get("/browse")
async def browse_folder():
    """
    Opens native Windows folder picker via Shell32 ctypes.
    No PowerShell, no tkinter required.
    """
    def _open_dialog():
        try:
            import ctypes
            import ctypes.wintypes as wt

            shell32 = ctypes.windll.shell32
            ole32   = ctypes.windll.ole32
            ole32.CoInitialize(None)

            class BROWSEINFO(ctypes.Structure):
                _fields_ = [
                    ("hwndOwner",      wt.HWND),
                    ("pidlRoot",       ctypes.c_void_p),
                    ("pszDisplayName", wt.LPWSTR),
                    ("lpszTitle",      wt.LPCWSTR),
                    ("ulFlags",        wt.UINT),
                    ("lpfn",           ctypes.c_void_p),
                    ("lParam",         ctypes.c_void_p),
                    ("iImage",         ctypes.c_int),
                ]

            BIF_RETURNONLYFSDIRS = 0x0001
            BIF_NEWDIALOGSTYLE   = 0x0040
            BIF_EDITBOX          = 0x0010

            buf = ctypes.create_unicode_buffer(32768)
            bi  = BROWSEINFO()
            bi.hwndOwner      = None
            bi.pidlRoot       = None
            bi.pszDisplayName = buf
            bi.lpszTitle      = "Select Download Folder"
            bi.ulFlags        = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX
            bi.lpfn           = None
            bi.lParam         = None

            shell32.SHBrowseForFolderW.restype = ctypes.c_void_p
            pidl = shell32.SHBrowseForFolderW(ctypes.byref(bi))

            if pidl:
                path_buf = ctypes.create_unicode_buffer(32768)
                shell32.SHGetPathFromIDListW(ctypes.c_void_p(pidl), path_buf)
                ole32.CoTaskMemFree(ctypes.c_void_p(pidl))
                ole32.CoUninitialize()
                return path_buf.value or None

            ole32.CoUninitialize()
            return None
        except Exception:
            return None

    loop = asyncio.get_event_loop()
    path = await loop.run_in_executor(None, _open_dialog)
    return {"path": path}


@app.post("/analyze")
def analyze(req: AnalyzeRequest):
    try:
        return downloader.analyze(req.url)
    except Exception as e:
        raise HTTPException(status_code=422, detail=str(e))


@app.post("/download")
def start_download(req: DownloadRequest):
    dl_id = downloader.start_download(
        url=req.url,
        output_dir=req.output_dir,
        filename=req.filename,
        mode=req.mode,
        resolution=req.resolution,
        fmt=req.fmt,
        start_tc=req.start_tc,
        end_tc=req.end_tc,
        metadata=req.metadata,
        subtitles=req.subtitles,
        thumbnail=req.thumbnail,
        chapters=req.chapters,
    )
    return {"id": dl_id}


@app.get("/progress/{dl_id}")
async def progress_stream(dl_id: str):
    async def generate() -> AsyncGenerator[str, None]:
        idle = 0
        last_pct = -1.0

        while True:
            state = downloader.get_progress(dl_id)

            if state is None:
                yield _sse({"status": "error", "error": "Unknown download ID"})
                break

            pct = state.get("percent", 0.0)
            if pct != last_pct or idle % 20 == 0:
                yield _sse(state)
                last_pct = pct

            status = state.get("status", "")
            if status in ("done", "error", "cancelled"):
                yield _sse(state)
                break

            idle = idle + 1 if pct == last_pct else 0
            if idle > 3000:  # 5 min idle cap
                yield _sse({"status": "error", "error": "Download timed out"})
                break

            await asyncio.sleep(0.1)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/cancel/{dl_id}")
def cancel(dl_id: str):
    if not downloader.cancel_download(dl_id):
        raise HTTPException(status_code=404, detail="Download ID not found")
    return {"cancelled": True}


def _sse(data: dict) -> str:
    return f"data: {json.dumps(data)}\n\n"
