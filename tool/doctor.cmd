@echo off
REM Full flutter doctor output. ASCII only - see run.cmd for why.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
endlocal
