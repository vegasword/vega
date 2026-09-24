@echo off
setlocal
where cl.exe >nul 2>&1 || call setup.bat

cd /d "%~dp0"

if exist "icons\makeico.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "icons\makeico.ps1" >nul 2>&1

set resource=
if exist "icons\vega.rc" set resource=-resource:icons/vega.rc

odin build . -out:vega.exe -o:speed -subsystem:windows %resource%
if errorlevel 1 (
	echo build failed
	exit /b 1
)

exit /b 0
