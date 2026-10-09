@echo off
REM ============================================================================
REM  LightNote - rebuild, run, and keep the window open.
REM
REM  This is the one to double-click after editing code. Unlike run.cmd it ends
REM  with "pause", so if the build fails you can actually read the error.
REM
REM  ASCII only - see tool\run.cmd for why (cmd.exe reads .cmd as GBK, so
REM  UTF-8 Chinese corrupts the parsing).
REM ============================================================================

setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\run.ps1" -Mode run
set "CODE=%ERRORLEVEL%"

echo.
echo ============================================================
if "%CODE%"=="0" (
  echo [LightNote] Done. The app window should be open.
) else (
  echo [LightNote] BUILD FAILED - exit code %CODE%
  echo Send the error text above to get it fixed.
)
echo ============================================================
echo.
pause

exit /b %CODE%
