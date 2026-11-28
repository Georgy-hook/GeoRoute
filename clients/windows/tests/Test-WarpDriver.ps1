#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$DriverPath)
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'Warp.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('georoute-driver-'+[guid]::NewGuid().ToString('N'))
try{
 $bundle=Join-Path $fixture 'bundle';$driverDirectory=Join-Path $bundle 'warp\driver'
 [IO.Directory]::CreateDirectory($driverDirectory)|Out-Null
 Copy-Item -LiteralPath $DriverPath -Destination (Join-Path $driverDirectory 'wintun.dll')
 Copy-Item -LiteralPath (Join-Path $source 'warp-runtime.json') -Destination (Join-Path $bundle 'warp-runtime.json')
 function Get-WarpRuntimeCache {return (Join-Path $fixture 'empty-cache')}
 function Invoke-WebRequest {throw 'Bundled driver preparation must not use the network'}
 $script:signaturePaths=[Collections.Generic.List[string]]::new()
 function Get-AuthenticodeSignature([string]$LiteralPath){$script:signaturePaths.Add($LiteralPath);Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $LiteralPath}
 $cache=Initialize-WarpRuntime $bundle -DriverOnly -SkipBootstrap
 $expected=(Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $bundle 'warp-runtime.json')|ConvertFrom-Json).wintun.sha256
 if((Get-FileHash -LiteralPath (Join-Path $cache 'wintun.dll')).Hash -ine $expected){throw 'Bundled driver integrity was not preserved'}
 if($script:signaturePaths.Count -ne 1 -or $script:signaturePaths[0] -ine (Join-Path $driverDirectory 'wintun.dll')){throw 'Preparation must select the bundled driver before installed applications'}
 if(@(Get-ChildItem -LiteralPath $cache -File).Count -ne 1){throw 'Driver-only preparation must not fetch proxy engines or account data'}
 Write-Output 'Bundled driver: empty cache, exact vendor SHA-256 and real signature passed; no network, installed VPN dependency or driver activation.'
}finally{
 $full=[IO.Path]::GetFullPath($fixture)
 if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-driver-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
