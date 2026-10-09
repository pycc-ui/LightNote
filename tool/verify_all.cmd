@echo off
REM Run the entire verification pipeline (analyze + test + build + launch check).
REM ASCII only - see run.cmd for why.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_all.ps1"
endlocal
