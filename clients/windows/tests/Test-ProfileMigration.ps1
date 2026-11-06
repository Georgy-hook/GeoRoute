#Requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'ProfileMigration.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-unified-'+[guid]::NewGuid().ToString('N'))
$before=(Get-FileHash (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')).Hash
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item (Join-Path $source 'profiles') $temp -Recurse
    $catalog=Get-Content (Join-Path $source 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $catalog.PSObject.Properties.Remove('UnifiedGeoHideVersion')
    $catalog.Profiles=@($catalog.Profiles|Where-Object id -notin @('gemini-us','gemini-eu'))
    ($catalog.Profiles|Where-Object id -eq 'primary').address='1'
    ($catalog.Profiles|Where-Object id -eq 'alternate').address='1'
    [IO.File]::WriteAllText((Join-Path $temp 'profiles/alternate.hosts'),"1 chatgpt.com`r`n1 files.oaiusercontent.com`r`n")
    ($catalog.Profiles|Where-Object id -eq 'us-eu').id='profile-legacy-combined'
    foreach($id in @('gemini-us','gemini-eu','25-10-12-00-08-1c6816ce','my-gemini')){
        $catalog.Profiles+=@([pscustomobject]@{id=$id;name=$id;hostsFile=('profiles/'+$id+'.hosts');address='31.25.239.132'})
        [IO.File]::WriteAllText((Join-Path $temp ('profiles/'+$id+'.hosts')),'31.25.239.132 gemini.google.com')
    }
    Write-GeoMigrationFile (Join-Path $temp 'profiles.json') ($catalog|ConvertTo-Json -Depth 15)
    Write-GeoMigrationFile (Join-Path $temp 'geohide-settings.json') '{"preferredProfileId":"gemini-eu","autoSelect":false,"eu":"31.25.239.132","manualServers":[{"region":"EU","address":"5.175.161.3"}]}'
    $custom=Join-Path $temp 'profiles/my-gemini.hosts';$customHash=(Get-FileHash $custom).Hash
    Update-GeoRouteBundledProfiles $temp
    $catalog=Get-Content (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert (@($catalog.Profiles|Where-Object id -in @('gemini-us','gemini-eu','25-10-12-00-08-1c6816ce')).Count -eq 0) 'Only the three retired profiles disappear from the catalog'
    Assert (@($catalog.Profiles|Where-Object id -eq 'my-gemini').Count -eq 1 -and (Get-FileHash $custom).Hash -eq $customHash) 'Custom service profiles and their bytes are preserved'
    foreach($entry in @($catalog.Profiles|Where-Object service -eq 'GeoHide')){
        $text=Get-Content (Join-Path $temp $entry.hostsFile) -Raw -Encoding UTF8
        Assert ($text -match ' chatgpt.com' -and $text -match ' gemini.google.com' -and $text -match ' files.oaiusercontent.com') 'Each bundled profile covers both services and files'
        Assert ($text -notmatch ' www.google.com') 'Migration cannot redirect Google Search without a successful server check'
    }
    Assert (($catalog.Profiles|Where-Object id -eq 'primary').address -ne '1') 'Invalid legacy address metadata is repaired from actual hosts'
    Assert (($catalog.Profiles|Where-Object id -eq 'alternate').address -ne ($catalog.Profiles|Where-Object id -eq 'primary').address) 'A corrupted backup gets a distinct fallback server'
    Assert (@($catalog.Profiles|Where-Object id -eq 'profile-legacy-combined').Count -eq 1) 'Imported combined profile keeps its ID'
    $settings=Get-Content (Join-Path $temp 'geohide-settings.json') -Raw|ConvertFrom-Json
    Assert ($settings.preferredProfileId -eq 'eu-primary' -and -not $settings.autoSelect -and $settings.manualServers[0].address -eq '5.175.161.3') 'Preference remaps without changing manual mode or manual servers'
    $backup=@(Get-ChildItem (Join-Path $temp 'backups') -Directory)
    Assert ($backup.Count -eq 1 -and (Get-Content (Join-Path $backup[0].FullName 'profiles.json') -Raw) -match 'gemini-eu') 'The old catalog remains available in a backup'
    $hash=(Get-FileHash (Join-Path $temp 'profiles.json')).Hash
    Update-GeoRouteBundledProfiles $temp
    Assert ((Get-FileHash (Join-Path $temp 'profiles.json')).Hash -eq $hash -and @(Get-ChildItem (Join-Path $temp 'backups') -Directory).Count -eq 1) 'Repeated startup does not rewrite data or create more backups'
    Assert ((Get-FileHash (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')).Hash -eq $before) 'Migration never applies a network route'
    Write-Output 'Unified migration passed: six shared profiles, exact retirement, backups, stable IDs, custom data, preference remapping, idempotence and untouched hosts.'
} finally {
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-unified-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
