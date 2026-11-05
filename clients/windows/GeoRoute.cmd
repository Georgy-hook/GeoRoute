@echo off
setlocal
if not exist "%~dp0_service\NextDNS-GUI.ps1" (
 echo GeoRoute: extract the entire ZIP before starting. The _service folder is missing.
 pause
 exit /b 1
)
pushd "%~dp0_service"
if errorlevel 1 exit /b 1
set "GeoRouteMode="
if "%~1"=="" goto launch
if /i "%~1"=="-Tray" set "GeoRouteMode=-Tray"
if /i "%~1"=="-Repair" set "GeoRouteMode=-Repair"
if /i "%~1"=="-SmokeTest" goto smoke
if not defined GeoRouteMode (
 popd
 exit /b 2
)
:launch
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0_service\NextDNS-GUI.ps1" %GeoRouteMode%
set "GeoRouteExit=%errorlevel%"
popd
exit /b %GeoRouteExit%
:smoke
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0_service\NextDNS-GUI.ps1" -SmokeTest
set "GeoRouteExit=%errorlevel%"
popd
exit /b %GeoRouteExit%
