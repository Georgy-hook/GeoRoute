#Requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-assets-'+[guid]::NewGuid().ToString('N'))
function Assert($Value,$Message){if(-not $Value){throw $Message}}
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    foreach($name in @('GeoHideWorker.ps1','GeoHide.ps1','GeoAvailability.ps1','GeoServices.ps1','ProfileMigration.ps1','ProfileCreation.ps1','GeoMonitorState.ps1')){Copy-Item (Join-Path $source $name) $temp}
    # Replace only transport in a disposable copy. Exercise the real worker's result logic.
    $probe=@'
function Get-NetIPConfiguration {
 # This is an offline worker test. Do not depend on transient runner NIC/CIM state.
 [pscustomobject]@{
  InterfaceAlias='Offline-fixture'
  InterfaceIndex=[Net.NetworkInformation.NetworkInterface]::LoopbackInterfaceIndex
  IPv4DefaultGateway=[pscustomobject]@{NextHop='127.0.0.1'}
  IPv4Address=@([pscustomobject]@{IPAddress='127.0.0.1'})
 }
}
function Probe-GeoAsset { Probe-Geo '142.250.0.1' 'gemini.gstatic.com' '/' }
function Probe-Geo($Address,$HostName,$Path) {
 if($HostName -eq 'gemini.gstatic.com' -and $Address -ne '142.250.0.1'){throw 'Assets must use the native Google route'}
 $status=if($HostName -eq 'www.google.com'){429}elseif($HostName -in @('files.oaiusercontent.com','gemini.gstatic.com','geminiweb-pa.clients6.google.com')){404}else{200}
 $tls=-not ($HostName -eq 'gemini.gstatic.com' -and -not (Test-Path (Join-Path $PSScriptRoot 'asset-ready')))
 return [pscustomobject]@{tcp=$true;tls=$tls;http=$status;country='NL';ms=12;error='';blocked=$false;location=''}
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'GeoProbe.ps1'),$probe,[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $temp 'geohide-servers.json'),' {"servers":[{"region":"EU","address":"143.20.64.192"}],"sources":[]}')
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $result=Join-Path $temp 'result.json'
    & $shell -NoProfile -File (Join-Path $temp 'GeoHideWorker.ps1') -ResultPath $result
    Assert ($LASTEXITCODE -eq 0) 'Worker completes with fake transport'
    $row=(Get-Content $result -Raw -Encoding UTF8|ConvertFrom-Json).rows[0]
    Assert (-not $row.GeminiReady -and -not $row.GeminiAssetTLS -and $row.GeminiError -match 'gemini.gstatic.com' -and $row.EligibleEU) 'A failed asset host cannot claim Gemini works or disable healthy ChatGPT'
    [IO.File]::WriteAllText((Join-Path $temp 'asset-ready'),'ready')
    & $shell -NoProfile -File (Join-Path $temp 'GeoHideWorker.ps1') -ResultPath $result
    Assert ($LASTEXITCODE -eq 0) 'Worker completes with healthy assets'
    $row=(Get-Content $result -Raw -Encoding UTF8|ConvertFrom-Json).rows[0]
    Assert ($row.GeminiReady -and $row.GeminiAssetTLS -and $row.GeminiAssetHTTP -eq 404) 'Expected resource-root 404 passes validated TLS'
    Write-Output 'Gemini worker assets passed: resource failure is explicit, ChatGPT survives, successful resource transport is required; all probes mocked.'
} finally {
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-assets-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
