@echo off
REM Inspect the sqlite database the app created. ASCII only - see run.cmd for why.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0inspect_db.ps1"
endlocal
