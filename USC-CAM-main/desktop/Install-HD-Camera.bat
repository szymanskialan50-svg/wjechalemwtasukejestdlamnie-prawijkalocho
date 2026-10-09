@echo off
rem Registers the virtual webcam "HD Camera iPhone" (needs admin, one time).
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "NAME=HD Camera iPhone"
cd /d "%~dp0driver"
rem remove the old name from earlier versions (ignore errors)
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera USC-CAM" HDCameraiPhone64.dll >nul 2>&1
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera USC-CAM" HDCameraiPhone32.dll >nul 2>&1
regsvr32 /s /n /i:UnityCaptureName="%NAME%" HDCameraiPhone64.dll
if %errorlevel% neq 0 ( echo Installing 64-bit filter failed. & pause & exit /b 1 )
regsvr32 /s /n /i:UnityCaptureName="%NAME%" HDCameraiPhone32.dll
echo.
echo Done. Restart Zoom / Discord / Teams / browser - the camera is called "%NAME%".
pause
