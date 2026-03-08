@echo off
cd /d "%~dp0"
start "" /min py main.py
timeout /t 2 /nobreak >nul
start http://127.0.0.1:8765/ui/downloader_v5.html