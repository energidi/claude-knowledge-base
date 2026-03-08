"""
main.py - Energidi / FETCH entry point.
Starts FastAPI on 127.0.0.1:8765, opens browser automatically.
Run:    python main.py
Packed: FETCH.exe
"""

import os, sys, time, socket, threading, webbrowser
from pathlib import Path
import uvicorn

# Fix Windows asyncio ConnectionResetError with ProactorEventLoop
if sys.platform == "win32":
    import asyncio
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

HOST = "127.0.0.1"
PORT = 8765


def _port_free(p: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex((HOST, p)) != 0


def _find_port(start: int) -> int:
    p = start
    while not _port_free(p):
        p += 1
        if p > start + 20:
            raise RuntimeError("No free port found in range.")
    return p


def _open_browser(url: str, delay: float = 1.4) -> None:
    time.sleep(delay)
    webbrowser.open(url)


def main() -> None:
    port   = _find_port(PORT)
    ui_url = f"http://{HOST}:{port}/ui/downloader_v5.html"

    print(f"\n  ╔══════════════════════════════════╗")
    print(f"  ║  FETCH  /  Energidi  v2.1.4      ║")
    print(f"  ╚══════════════════════════════════╝")
    print(f"  Server  →  http://{HOST}:{port}")
    print(f"  UI      →  {ui_url}")
    print(f"  Press Ctrl+C to quit.\n")

    threading.Thread(target=_open_browser, args=(ui_url,), daemon=True).start()

    # Resolve base dir — works both in dev and when frozen by PyInstaller
    base = Path(sys._MEIPASS) if getattr(sys, "frozen", False) else Path(__file__).parent  # type: ignore[attr-defined]
    os.chdir(base)

    uvicorn.run(
        "server:app",
        host=HOST,
        port=port,
        log_level="warning",
        access_log=False,
    )


if __name__ == "__main__":
    main()
