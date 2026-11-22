#Requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHide.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-selection-'+[guid]::NewGuid().ToString('N'))
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$before=(Get-FileHash $hosts).Hash
try {
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item (Join-Path $source 'profiles') $temp -Recurse
    foreach($name in @('profiles.json','geohide-servers.json','connection-routes.json')){Copy-Item (Join-Path $source $name) $temp}
    $node=[pscustomobject]@{Region='EU';Address='143.20.64.192';CheckedAt=(Get-Date).ToString('o');CheckState='Complete';SourceActive=$true;EligibleEU=$true;FilesTLS=$true;FilesHTTP=404;GeminiReady=$true;GeminiChallenge=$false;GeminiVerificationTLS=$true;GeminiVerificationHTTP=429}
    $report=[pscustomobject]@{running=$false;rows=@($node)}
    $id=Save-GeoMonitorProfile $temp EU $node.Address $report
    Assert ($id -eq 'monitor-selected' -and (Get-GeoProfileAvailability $temp $id $report).Ready) 'Fresh successful row creates a usable managed profile'
    $path=Join-Path $temp 'profiles/monitor-selected.hosts'
    $text=[IO.File]::ReadAllText($path)
    foreach($domain in @('chatgpt.com','files.oaiusercontent.com','gemini.google.com','gemini.gstatic.com','www.google.com')){Assert ($text.Contains($node.Address+' '+$domain)) ('Same IP for '+$domain)}
    $node.Address='31.25.239.132';$node.GeminiVerificationTLS=$false
    Save-GeoMonitorProfile $temp EU $node.Address $report|Out-Null
    Assert (-not [IO.File]::ReadAllText($path).Contains('www.google.com')) 'Unverified Google route is excluded'
    $catalog=Get-Content (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert (@($catalog.Profiles|Where-Object monitorSelection).Count -eq 1) 'Repeated selection reuses one card'
    $hash=(Get-FileHash $path).Hash
    Save-GeoProfile $temp (Read-GeoSettings $temp) $report
    Assert ((Get-FileHash $path).Hash -eq $hash) 'Regional auto selection cannot overwrite explicitly selected node'
    foreach($kind in @('stale','checking','retired','files','running')){
        $copy=$report|ConvertTo-Json -Depth 12|ConvertFrom-Json
        switch($kind){stale{$copy.rows[0].CheckedAt=(Get-Date).AddDays(-1).ToString('o')}checking{$copy.rows[0].CheckState='Checking'}retired{$copy.rows[0].SourceActive=$false}files{$copy.rows[0].FilesHTTP=503}running{$copy.running=$true}}
        $caught=$false;try{Save-GeoMonitorProfile $temp EU $node.Address $copy|Out-Null}catch{$caught=$true}
        Assert ($caught -and (Get-FileHash $path).Hash -eq $hash) ('Reject '+$kind+' without rewriting profile')
    }
    # A catalog commit failure must roll back the prepared hosts file.
    $lock=[IO.File]::Open((Join-Path $temp 'profiles.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$node.GeminiVerificationTLS=$true;$caught=$false;try{Save-GeoMonitorProfile $temp EU $node.Address $report|Out-Null}catch{$caught=$true}}finally{$lock.Dispose()}
    Assert ($caught -and (Get-FileHash $path).Hash -eq $hash) 'Failed catalog commit restores profile bytes'
    $catalog=Read-GeoCatalog $temp
    Assert (-not @($catalog.servers|Where-Object region -eq 'RU').Count) 'Closed RU seeds never return from the old local catalog'
    $closed=[pscustomobject]@{Role='RU';Address='159.194.200.33';Files=$false;Service='ChatGPT'}
    Assert (-not (Test-GeoRequirements @($closed) ([pscustomobject]@{rows=@()})).Ready) 'Old successful RU cache cannot unlock closed node'
    Assert ((Get-FileHash $hosts).Hash -eq $before) 'Preparation never touches system hosts'
    Write-Output 'Monitor selection passed: same-IP routes, reusable profile, stale/failed rejection, rollback, explicit address retention, closed RU pool; system hosts unchanged.'
} finally {
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-selection-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
