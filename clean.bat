@echo off
setlocal
cd /d "%~dp0"
del /q vega.* *.bmp *.png icons\vega.res 2>nul
exit /b 0
