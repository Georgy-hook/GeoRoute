$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHide.ps1')
. (Join-Path $source 'Home.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$page=[pscustomobject]@{tls=$true;http=200;location='';blocked=$false}
$api=[pscustomobject]@{tls=$true;http=404}
Assert (Test-GeoGeminiProbe $page $api) 'Gemini page and expected API-root 404 are reachable'
$page.http=302;$page.location='https://www.google.com/sorry/index?continue=https://gemini.google.com/app'
Assert (Test-GeoGeminiProbe $page $api) 'Google challenge is a reachable route requiring user action'
$page.location='https://accounts.google.com/ServiceLogin'
Assert (Test-GeoGeminiProbe $page $api) 'Trusted sign-in redirect is reachable'
$page.location='https://accounts.google.com.evil.example/login'
Assert (-not (Test-GeoGeminiProbe $page $api)) 'Untrusted redirect is not accepted'
$page.http=200;$page.location='';$page.blocked=$true
Assert (-not (Test-GeoGeminiProbe $page $api)) 'Regional block is not healthy'
$page.blocked=$false;$api.http=503
Assert (-not (Test-GeoGeminiProbe $page $api)) 'Failed API is not hidden by a working page'
$api.http=404;$page.tls=$false
Assert (-not (Test-GeoGeminiProbe $page $api)) 'TLS must validate normally'
foreach($domain in @('google.com','accounts.google.com','mail.google.com','unrelated.googleapis.com','gemini.google.com.evil.example')){Assert (-not (Test-GeoGeminiDomain $domain)) ('Not broadly routed: '+$domain)}
# Exercise the actual import validator without executing administrative backend actions.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Profiles.ps1'),[ref]$tokens,[ref]$parseErrors)
$validator=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-Domain'},$true)
Invoke-Expression $validator.Extent.Text
foreach($domain in @(Get-GeoGeminiDomains)){Assert-Domain $domain}
$rejected=$false;try{Assert-Domain 'accounts.google.com'}catch{$rejected=$true}
Assert $rejected 'Backend still rejects arbitrary Google account routing'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-gemini-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'profiles') -Destination $temp -Recurse
    foreach($name in @('profiles.json','connection-routes.json')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $temp}
    $settings=Read-GeoSettings $temp
    $eu=[pscustomobject]@{Region='EU';Address='37.221.93.128';SourceActive=$true;CheckState='Complete';CheckedAt=(Get-Date).ToString('o');EligibleEU=$false;GeminiReady=$true;GeminiChallenge=$false;FilesTLS=$false;FilesHTTP=$null}
    $report=[pscustomobject]@{rows=@($eu);running=$false}
    Save-GeoProfile $temp $settings $report
    Assert (Get-GeoProfileAvailability $temp 'gemini-eu' $report).Ready 'Gemini-only profile works independently of ChatGPT and OpenAI files'
    Assert (-not (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready) 'Combined profile still requires ChatGPT'
    $text=Get-Content -LiteralPath (Join-Path $temp 'profiles/us-eu.hosts') -Raw -Encoding UTF8
    Assert ($text -match '45.13.237.213 gemini.google.com') 'Combined route sends Gemini through EU'
    $geminiText=Get-Content -LiteralPath (Join-Path $temp 'profiles/gemini-eu.hosts') -Raw -Encoding UTF8
    Assert ($geminiText -match '37.221.93.128 gemini.google.com' -and $geminiText -notmatch 'chatgpt.com') 'Gemini-only hosts select their own working endpoint'
    $eu.GeminiChallenge=$true
    $state=Get-GeoProfileAvailability $temp 'gemini-eu' $report
    Assert ($state.Ready -and $state.State -eq 'attention' -and $state.Reason -match 'CAPTCHA') 'Challenge is selectable with an explicit warning'
    $hostsPath=Join-Path $temp 'hosts-test'
    [IO.File]::WriteAllText($hostsPath,"# BEGIN CHATGPT-US-WINDOWS`r`n"+$geminiText+"# END CHATGPT-US-WINDOWS`r`n")
    Assert ((Get-GeoHomeState $temp $report $hostsPath).State -eq 'attention') 'Active challenge is not shown as fully healthy'
    $eu.GeminiChallenge=$false;$eu.GeminiReady=$false
    Assert (-not (Get-GeoProfileAvailability $temp 'gemini-eu' $report).Ready) 'Failed Gemini node is disabled'
    $eu.GeminiReady=$true;$eu.CheckedAt=(Get-Date).AddMinutes(-10).ToString('o')
    Assert (-not (Get-GeoProfileAvailability $temp 'gemini-eu' $report).Ready) 'Stale probe does not unlock Gemini'
    $eu.CheckedAt=(Get-Date).ToString('o');$eu.EligibleEU=$true;$eu.FilesTLS=$true;$eu.FilesHTTP=404;$eu.GeminiReady=$false
    $us=[pscustomobject]@{Region='US';Address=$settings.us;SourceActive=$true;CheckedAt=(Get-Date).ToString('o');EligibleUS=$true}
    Assert (-not (Get-GeoSelection $settings ([pscustomobject]@{rows=@($us,$eu)})).ready) 'Combined selection is not ready if only Gemini has failed'
    Write-Output 'Gemini checks passed: narrow domains, import validator, API/TLS, redirects, challenge, independent profiles, failure and stale probes.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-gemini-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
