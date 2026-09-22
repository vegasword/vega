@echo off
setlocal
cd /d "%~dp0"
start "" vega.exe %*
exit /b 0
