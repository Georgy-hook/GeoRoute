$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'GeoHide.ps1')
. (Join-Path $root 'Home.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-home-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
$path=Join-Path $temp 'hosts'
try{
    [IO.File]::WriteAllText($path,"127.0.0.1 localhost`r`n")
    $state=Get-GeoHomeState $temp $null $path
    Assert (-not $state.On -and $state.State -eq 'off') 'Off is normal, not a DNS warning'
    [IO.File]::WriteAllText($path,"# BEGIN CHATGPT-US-WINDOWS`r`n37.221.93.128 chatgpt.com`r`n37.221.93.128 files.oaiusercontent.com`r`n# END CHATGPT-US-WINDOWS`r`n")
    $row=[pscustomobject]@{Region='EU';Address='37.221.93.128';CheckedAt=(Get-Date).ToString('o');SourceActive=$true;EligibleEU=$true;FilesTLS=$true;FilesHTTP=404}
    $report=[pscustomobject]@{running=$false;rows=@($row)}
    $state=Get-GeoHomeState $temp $report $path
    Assert ($state.On -and $state.State -eq 'ready') 'Healthy applied hosts can be green without NextDNS Bridge'
    [IO.File]::WriteAllText((Join-Path $temp 'profiles.json'),'{"Profiles":[{"id":"eu-primary","service":"GeoHide","hostsFile":"prepared.hosts"}]}')
    $oldHosts=[IO.File]::ReadAllText($path)
    [IO.File]::WriteAllText((Join-Path $temp 'prepared.hosts'),$oldHosts+"37.221.93.128 gemini.google.com`r`n")
    [IO.File]::WriteAllText($path,$oldHosts.Replace("# BEGIN CHATGPT-US-WINDOWS`r`n","# BEGIN CHATGPT-US-WINDOWS`r`n# Profile ID: eu-primary`r`n"))
    $state=Get-GeoHomeState $temp $report $path
    Assert ($state.On -and $state.State -eq 'attention' -and $state.Title -like '*обновите профиль*') 'Old ChatGPT-only hosts cannot pretend the new shared profile is applied'
    [IO.File]::WriteAllText($path,$oldHosts)
    $row.EligibleEU=$false
    Assert ((Get-GeoHomeState $temp $report $path).State -eq 'unavailable') 'A failed applied node is reported honestly'
    $row.EligibleEU=$true;$row.CheckedAt=(Get-Date).AddMinutes(-15).ToString('o')
    Assert ((Get-GeoHomeState $temp $report $path).State -eq 'checking') 'Stale result is checking, not green or a permanent warning'
    Assert ((Get-GeoHomeState $temp $null $path).State -eq 'checking') 'Missing probe is not green'
    [IO.File]::WriteAllText($path,'# BEGIN CHATGPT-US-WINDOWS')
    Assert ((Get-GeoHomeState $temp $report $path).State -eq 'error') 'Broken managed block is a real configuration error'
    Write-Output 'Home states passed: off, checking, ready without Bridge, real failure, stale result and broken configuration.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-home-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
