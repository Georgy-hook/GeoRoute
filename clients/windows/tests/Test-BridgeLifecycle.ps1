#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PythonExe)
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service\bridge\NextDNSBridge.cs'
$tests=Join-Path $PSScriptRoot 'BridgeLifecycleTests.cs'
$code=[IO.File]::ReadAllText($source)+[Environment]::NewLine+[IO.File]::ReadAllText($tests)
Add-Type -TypeDefinition $code -Language CSharp -ReferencedAssemblies @('System.dll','System.Core.dll','System.ServiceProcess.dll')
[NextDNSBridge.Tests.Lifecycle]::Run($PythonExe)
