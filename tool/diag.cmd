@echo off
REM Diagnostic wrapper. ASCII only - see run.cmd for why.
setlocal

echo === environment self-check ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diag.ps1"

endlocal
