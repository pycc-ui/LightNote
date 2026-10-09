@echo off
REM Qing Notes - one-click build/run (batch wrapper)
REM
REM IMPORTANT: this file must stay ASCII-only. cmd.exe reads .cmd files using
REM the OEM codepage (GBK here), so UTF-8 Chinese text corrupts the parsing.
REM Chinese output comes from run.ps1 instead.
REM
REM Usage (from any directory):
REM   run.cmd             build debug and run
REM   run.cmd build       build debug only
REM   run.cmd release     build release (self-contained, can be copied away)
REM   run.cmd test        run tests
REM   run.cmd analyze     static analysis
REM   run.cmd doctor      environment check
REM   run.cmd pubget      flutter pub get
REM   run.cmd raw <args>  run an arbitrary flutter command (for debugging)
setlocal

set "MODE=%~1"
if "%MODE%"=="" set "MODE=run"

REM "raw" passes everything after the mode straight to flutter.
REM Needed when diagnosing toolchain problems (e.g. `run.cmd raw pub get -v`).
if /I "%MODE%"=="raw" (
  set "REST=%*"
  setlocal enabledelayedexpansion
  set "REST=!REST:*raw =!"
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -Mode raw -Args "!REST!"
  set "CODE=!ERRORLEVEL!"
  endlocal & exit /b %CODE%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -Mode %MODE%
set "CODE=%ERRORLEVEL%"

exit /b %CODE%
