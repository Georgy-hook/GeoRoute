$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'GeoHide.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Node($Region,$Address){return [pscustomobject]@{Region=$Region;Address=$Address;SourceActive=$true;CheckedAt=(Get-Date).ToString('o');EligibleUS=($Region -eq 'US');EligibleEU=($Region -eq 'EU');EligibleRU=($Region -eq 'RU');FilesTLS=$true;FilesHTTP=404}}
$settings=[pscustomobject]@{us='192.255.159.240';eu='45.13.237.213';ru='159.194.200.33';autoSelect=$true;manualServers=@()}
$us=Node US '192.255.159.240';$eu=Node EU '37.221.93.128';$ru=Node RU '193.233.112.67'
$report=[pscustomobject]@{rows=@($us,$eu,$ru)}
$selection=Get-GeoSelection $settings $report
Assert ($selection.us -eq $settings.us -and $selection.eu -eq $eu.Address) 'A failed EU is replaced without changing healthy US'
Assert ($selection.ru -eq $ru.Address -and $selection.ruReady) 'RU discovered and selected independently'
$onlyEU=[pscustomobject]@{rows=@($eu)}
$selection=Get-GeoSelection $settings $onlyEU
Assert (-not $selection.ready -and $selection.eu -eq $eu.Address -and $selection.euReady) 'EU updates even when every US is unavailable'
$catalog=[pscustomobject]@{servers=@([pscustomobject]@{region='EU';address='45.13.237.213';origin='old'},[pscustomobject]@{region='US';address=$us.Address;origin='old'})}
Set-GeoRegionCatalog $catalog EU @($eu.Address) 'provider'
Assert (@($catalog.servers|Where-Object region -eq 'US').Count -eq 1) 'Region refresh retains other regions'
Assert (@($catalog.retired|Where-Object address -eq '45.13.237.213').Count -eq 1) 'Removed endpoint is tracked as retired'
Set-GeoRegionCatalog $catalog EU @('45.13.237.213') 'provider'
Assert (@($catalog.retired|Where-Object address -eq '45.13.237.213').Count -eq 0) 'Reappearing node is restored'
$caught=$false;try{Set-GeoRegionCatalog $catalog RU @('127.0.0.1') 'provider'}catch{$caught=$true}
Assert $caught 'Malformed or empty provider result cannot erase a region'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-regions-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'profiles') -Destination $temp -Recurse
    foreach($name in @('profiles.json','connection-routes.json')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $temp}
    $selection=Get-GeoSelection $settings $report
    $settings.eu=$selection.eu;$settings.ru=$selection.ru
    Save-GeoProfile $temp $settings $report
    Assert (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready 'A healthy mixed profile can be selected'
    Assert (Get-GeoProfileAvailability $temp 'ru-primary' $report).Ready 'RU profile follows new healthy RU node'
    $eu.EligibleEU=$false
    $state=Get-GeoProfileAvailability $temp 'us-eu' $report
    Assert (-not $state.Ready -and $state.Reason -like '*EU*') 'Dead EU blocks mixed profile despite healthy US'
    $eu.EligibleEU=$true;$eu.FilesHTTP=503
    Assert (-not (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready) 'Attachment HTTP 503 is not healthy TLS'
    $eu.FilesHTTP=404;$eu.CheckedAt=(Get-Date).AddMinutes(-10).ToString('o')
    Assert (-not (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready) 'Stale measurements do not unlock a card'
    $eu.CheckedAt=(Get-Date).ToString('o');$eu.SourceActive=$false
    Assert (-not (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready) 'Provider-retired endpoint cannot be selected'
    $eu.SourceActive=$true
    Save-GeoProfile $temp $settings $onlyEU
    Assert (-not (Get-GeoProfileAvailability $temp 'primary' $onlyEU).Ready) 'No working US must not create a healthy US card'
    Assert (Get-GeoProfileAvailability $temp 'eu-primary' $onlyEU).Ready 'EU-only profile remains usable without US'
    Write-Output 'Regional updates passed: independent US/EU/RU recovery, provider removal/reappearance, mixed-profile rejection, stale checks and attachment failures.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-regions-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
