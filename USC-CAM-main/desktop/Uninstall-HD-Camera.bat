@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0driver"
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera iPhone" HDCameraiPhone64.dll
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera iPhone" HDCameraiPhone32.dll
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera USC-CAM" HDCameraiPhone64.dll >nul 2>&1
regsvr32 /s /u /n /i:UnityCaptureName="HD Camera USC-CAM" HDCameraiPhone32.dll >nul 2>&1
echo Removed.
pause
