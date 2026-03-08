# build.spec - PyInstaller config for FETCH.exe
# Usage: pyinstaller build.spec

from PyInstaller.building.api import PYZ, EXE
from PyInstaller.building.build_main import Analysis

a = Analysis(
    ["main.py"],
    pathex=[],
    binaries=[],
    datas=[
        ("downloader_v5.html", "."),
        ("assets/fetch.ico", "assets"),
    ],
    hiddenimports=[
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        "fastapi",
        "yt_dlp",
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="FETCH",
    debug=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    icon="assets/fetch.ico",
)
