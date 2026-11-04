$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'GeoHide.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
Assert (-not (Test-GeoAddress '127.0.0.1')) 'Loopback rejected'
Assert (-not (Test-GeoAddress '192.168.1.1')) 'Private rejected'
Assert (-not (Test-GeoAddress 'not-an-ip')) 'Invalid address rejected'
$settings=[pscustomobject]@{us='192.255.159.241';eu='45.13.237.213';autoSelect=$true;manualServers=@()}
$rows=@([pscustomobject]@{Region='US';Address='192.255.159.240';EligibleUS=$true;EligibleEU=$false},[pscustomobject]@{Region='EU';Address='45.13.237.213';EligibleUS=$false;EligibleEU=$true})
$report=[pscustomobject]@{rows=$rows}
$selected=Get-GeoSelection $settings $report
Assert ($selected.ready -and $selected.us -eq '192.255.159.240') 'Dead US selection replaced'
$settings.us='192.255.159.240'
Assert ((Get-GeoSelection $settings $report).us -eq $settings.us) 'Healthy selection retained'
Assert (-not (Get-GeoSelection $settings ([pscustomobject]@{rows=@()})).ready) 'No pair is not ready'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('geohide-test-'+[guid]::NewGuid().ToString('N'))
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$before=(Get-FileHash -LiteralPath $hosts).Hash
try{
    [IO.Directory]::CreateDirectory((Join-Path $temp 'profiles'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'profiles.json') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $root 'profiles\us-eu.hosts') -Destination (Join-Path $temp 'profiles')
    Copy-Item -LiteralPath (Join-Path $root 'connection-routes.json') -Destination $temp
    Save-GeoProfile $temp $settings $report
    $text=Get-Content -LiteralPath (Join-Path $temp 'profiles\us-eu.hosts') -Raw
    Assert ($text -match '192.255.159.240 chatgpt.com') 'ChatGPT uses US'
    Assert ($text -match '45.13.237.213 files.oaiusercontent.com') 'File root uses EU'
    Assert ($text -match '45.13.237.213 sdmntprwestus.oaiusercontent.com') 'Storage subdomain uses EU'
    $routes=Get-Content -LiteralPath (Join-Path $temp 'connection-routes.json') -Raw|ConvertFrom-Json
    Assert ($routes.routes[1].addresses[0] -eq $settings.us) 'Route health follows selected address'
    $saved=Read-GeoSettings $temp
    Assert ($saved.us -eq $settings.us) 'Settings persist'
    $settings.us='127.0.0.1';$threw=$false
    try{Save-GeoProfile $temp $settings $report}catch{$threw=$true}
    Assert $threw 'Invalid save rejected'
    Assert ((Get-FileHash -LiteralPath $hosts).Hash -eq $before) 'System hosts unchanged'
    $settings.us='192.255.159.240'
    $catalog=Get-Content -LiteralPath (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    ($catalog.Profiles|Where-Object id -eq 'us-eu').id='profile-legacy'
    Write-GeoJson (Join-Path $temp 'profiles.json') $catalog
    Assert ((Get-GeoCombinedId $temp) -eq 'profile-legacy') 'Existing imported combined ID retained'
    Save-GeoProfile $temp $settings $report
    Assert ((Get-GeoCombinedId $temp) -eq 'profile-legacy') 'Save preserves imported combined ID'
    $fakeHosts=Join-Path $temp 'hosts-test'
    $desired=Get-Content -LiteralPath (Join-Path $temp 'profiles\us-eu.hosts') -Raw -Encoding UTF8
    [IO.File]::WriteAllText($fakeHosts,"127.0.0.1 localhost`r`n",[Text.UTF8Encoding]::new($false))
    Assert (-not (Get-GeoApplicationState $temp $fakeHosts)) 'Saved configuration is not applied'
    [IO.File]::WriteAllText($fakeHosts,"# BEGIN CHATGPT-US-WINDOWS`r`n"+$desired+"# END CHATGPT-US-WINDOWS`r`n",[Text.UTF8Encoding]::new($false))
    Assert (Get-GeoApplicationState $temp $fakeHosts) 'Actual matching managed hosts is applied'
    [IO.File]::WriteAllText($fakeHosts,(Get-Content $fakeHosts -Raw).Replace('192.255.159.240','192.3.233.253'),[Text.UTF8Encoding]::new($false))
    Assert (-not (Get-GeoApplicationState $temp $fakeHosts)) 'A different active US address is not applied'
    Write-Output 'GeoHide tests passed: selection, retention, unavailable pool, validation, persistence, US/EU mapping; system hosts unchanged.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith(([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^geohide-test-[a-f0-9]{32}$'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
