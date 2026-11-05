#Requires -Version 5.1
$ErrorActionPreference='Stop'
$client=Split-Path $PSScriptRoot -Parent
$output=Join-Path $client '.build\native-tests'
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $shell -NoProfile -File (Join-Path $client '_service\Build-Launcher.ps1') -Tests -OutputDirectory $output
if($LASTEXITCODE -ne 0){throw 'Cannot build launcher protocol tests'}
& (Join-Path $output 'GeoRoute.Launcher.Tests.exe')
if($LASTEXITCODE -ne 0){throw 'Native launcher protocol tests failed'}
