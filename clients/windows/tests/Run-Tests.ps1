#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonExe='python.exe')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $shell -NoProfile -File (Join-Path $PSScriptRoot 'Test-LauncherProtocol.ps1')
if($LASTEXITCODE -ne 0){throw 'Launcher protocol tests failed.'}
& $PythonExe -I (Join-Path $PSScriptRoot 'test_bridge_protocol.py')
if($LASTEXITCODE -ne 0){throw 'Bridge tests failed.'}
& (Join-Path $PSScriptRoot 'Test-GeoHide.ps1')
& (Join-Path $PSScriptRoot 'Test-GeoHideEditor.ps1')
& (Join-Path $PSScriptRoot 'Test-GeoRegions.ps1')
& (Join-Path $PSScriptRoot 'Test-Home.ps1')
& (Join-Path $PSScriptRoot 'Test-GeoMonitor.ps1')
& (Join-Path $PSScriptRoot 'Test-Gemini.ps1')
& (Join-Path $PSScriptRoot 'Test-ProfileCreation.ps1')
& (Join-Path $PSScriptRoot 'Test-RepairCenter.ps1')
& (Join-Path $PSScriptRoot 'Test-ConnectionRecovery.ps1')
& (Join-Path $PSScriptRoot 'Test-HttpProxy.ps1')
& (Join-Path $PSScriptRoot 'Test-NetworkRestore.ps1')
& (Join-Path $PSScriptRoot 'Test-BridgeMigration.ps1')
foreach($script in @('NextDNS-GUI.ps1','RepairCenter.ps1','HttpProxyDialog.ps1')){
 & $shell -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path (Join-Path $root '_service') $script) -SmokeTest
 if($LASTEXITCODE -ne 0){throw ('UI smoke failed: '+$script)}
}
Write-Output 'Windows client checks passed; no network settings or browser sessions changed.'
