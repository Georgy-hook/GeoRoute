# Shared, deliberately narrow Gemini allowlist. Source: GeoHide's Google Gemini AI section.
# www.google.com must share Gemini's egress for Google's verification; this also routes Search.
# No google.com suffix rule, accounts.google.com, Gmail or whole Google API/storage zones.
function Get-GeoMonitoringChoices {
    return @([pscustomobject]@{Minutes=0;Label='Никогда'},[pscustomobject]@{Minutes=30;Label='Раз в 30 минут'},[pscustomobject]@{Minutes=60;Label='Раз в час'},[pscustomobject]@{Minutes=120;Label='Раз в 2 часа'},[pscustomobject]@{Minutes=360;Label='Раз в 6 часов'},[pscustomobject]@{Minutes=720;Label='Раз в 12 часов'},[pscustomobject]@{Minutes=1440;Label='Раз в сутки'})
}
function Read-GeoMonitoringPreference([string]$Path) {
    try {
        $settings=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
        $value=$settings.AutoCheckMinutes
        if($null -ne $value -and [string]$value -match '^\d+$' -and [int]$value -in @(Get-GeoMonitoringChoices|ForEach-Object Minutes)){return [int]$value}
    }catch{}
    return 120
}
function Get-GeoMonitoringMinutes {
    if($null -eq $script:geoMonitoringMinutes){$script:geoMonitoringMinutes=Read-GeoMonitoringPreference (Join-Path $PSScriptRoot 'GUI-settings.json')}
    return [int]$script:geoMonitoringMinutes
}
function Set-GeoMonitoringMinutes([int]$Minutes) {
    if($Minutes -notin @(Get-GeoMonitoringChoices|ForEach-Object Minutes)){throw 'Выберите интервал из списка.'}
    $script:geoMonitoringMinutes=$Minutes
}
function Get-GeoMonitoringInterval {
    $minutes=Get-GeoMonitoringMinutes
    if($minutes -gt 0){return [timespan]::FromMinutes($minutes)}
    return $null
}
function Get-GeoMonitoringSummary {
    $minutes=Get-GeoMonitoringMinutes
    if($minutes -eq 0){return 'Автопроверка выключена'}
    return 'Автопроверка: '+[string](@(Get-GeoMonitoringChoices|Where-Object Minutes -eq $minutes)[0].Label).ToLowerInvariant()
}
function Test-GeoMonitoringDue([datetime]$LastCheck) {
    $interval=Get-GeoMonitoringInterval
    return $null -ne $interval -and ((Get-Date)-$LastCheck) -ge $interval
}
function Test-GeoObservationFresh($Node) {
    if(-not $Node -or -not $Node.PSObject.Properties['CheckedAt']){return $false}
    $at=[datetime]::MinValue
    if(-not [datetime]::TryParse([string]$Node.CheckedAt,[ref]$at)){return $false}
    $age=(Get-Date)-$at
    # Keep the previous observation usable while the next scheduled scan finishes.
    $interval=Get-GeoMonitoringInterval
    if($null -eq $interval){$interval=[timespan]::FromHours(2)}
    return $age.TotalSeconds -ge -60 -and $age -lt $interval.Add([timespan]::FromMinutes(10))
}
function Get-GeoGeminiDomains {
    return @('gemini.google.com','gemini.google','bard.google.com','www.google.com',
        'geminiweb-pa.clients.google.com','geminiweb-pa.clients6.google.com',
        'generativelanguage.googleapis.com','geller-pa.googleapis.com',
        'proactivebackend-pa.googleapis.com','robinfrontend-pa.googleapis.com')
}
function Test-GeoGeminiDomain([string]$Domain) {
    return $Domain.ToLowerInvariant() -in @(Get-GeoGeminiDomains)
}
function Test-GeoGoogleRoute($Node) {
    if(-not $Node){return $false}
    if(($Node.PSObject.Properties['SourceActive'] -and $Node.SourceActive -eq $false) -or ($Node.PSObject.Properties['CheckState'] -and $Node.CheckState -in @('Queued','Checking','Interrupted'))){return $false}
    if($Node.PSObject.Properties['CheckedAt'] -and -not (Test-GeoObservationFresh $Node)){return $false}
    return [bool](($Node.PSObject.Properties['GeminiVerificationTLS'] -and $Node.GeminiVerificationTLS -and $Node.GeminiVerificationHTTP -in @(200,204,400,429)) -or ($Node.PSObject.Properties['GeminiSharedHTTP2'] -and $Node.GeminiSharedHTTP2 -and $Node.GeminiReady))
}
function Test-GeoGeminiProbe($Page,$API,$Verification=$null) {
    if($Page.location -match '^https://www\.google\.com/sorry/' -and (-not $Verification -or -not $Verification.tls -or $Verification.http -notin @(200,400,429))){return $false}
    $pageOk=$Page.tls -and ($Page.http -eq 200 -or ($Page.http -in @(301,302,303,307,308) -and ($Page.location -match '^https://accounts\.google\.com/' -or $Page.location -match '^https://www\.google\.com/sorry/')))
    return [bool]($pageOk -and -not $Page.blocked -and $API.tls -and $API.http -in @(200,204,400,401,404,405))
}
