$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHide.ps1')
. (Join-Path $source 'Home.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$page=[pscustomobject]@{tls=$true;http=200;location='';blocked=$false}
$api=[pscustomobject]@{tls=$true;http=404}
Assert (Test-GeoGeminiProbe $page $api) 'Gemini page and expected API-root 404 are reachable'
$page.http=302;$page.location='https://www.google.com/sorry/index?continue=https://gemini.google.com/app'
$verification=[pscustomobject]@{tls=$true;http=429}
Assert (Test-GeoGeminiProbe $page $api $verification) 'Google challenge is reachable through the same server'
$verification.tls=$false
Assert (-not (Test-GeoGeminiProbe $page $api $verification)) 'A redirect alone cannot prove that the Google verification page opens'
$verification.tls=$true
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
Assert (Test-GeoGeminiDomain 'www.google.com') 'Only the exact Google verification frontend is included'
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
    $eu=[pscustomobject]@{Region='EU';Address='37.221.93.128';SourceActive=$true;CheckState='Complete';CheckedAt=(Get-Date).ToString('o');EligibleEU=$true;GeminiReady=$true;GeminiChallenge=$false;GeminiVerificationTLS=$true;GeminiVerificationHTTP=429;FilesTLS=$true;FilesHTTP=404}
    $report=[pscustomobject]@{rows=@($eu);running=$false}
    Save-GeoProfile $temp $settings $report
    Assert (Get-GeoProfileAvailability $temp 'eu-primary' $report).Ready 'One regional profile covers ChatGPT, Gemini and files'
    Assert (-not (Get-GeoProfileAvailability $temp 'us-eu' $report).Ready) 'Combined profile still requires ChatGPT'
    $text=Get-Content -LiteralPath (Join-Path $temp 'profiles/us-eu.hosts') -Raw -Encoding UTF8
    Assert ($text -match '45.13.237.213 gemini.google.com') 'Combined route sends Gemini through EU'
    $geminiText=Get-Content -LiteralPath (Join-Path $temp 'profiles/eu-primary.hosts') -Raw -Encoding UTF8
    Assert ($geminiText -match '37.221.93.128 gemini.google.com' -and $geminiText -match '37.221.93.128 www.google.com' -and $geminiText -match '37.221.93.128 chatgpt.com') 'Gemini and Google verification use the same endpoint in a shared profile'
    $catalog=Get-Content -LiteralPath (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert (@($catalog.Profiles|Where-Object id -in @('gemini-us','gemini-eu')).Count -eq 0) 'Automatic refresh never recreates retired Gemini cards'
    $eu.GeminiVerificationTLS=$false
    Save-GeoProfile $temp $settings $report
    Assert ((Get-Content (Join-Path $temp 'profiles/eu-primary.hosts') -Raw) -notmatch 'www.google.com') 'An unsupported verification frontend cannot break Google Search'
    $eu.GeminiVerificationTLS=$true
    Save-GeoProfile $temp $settings $report
    $eu.GeminiChallenge=$true
    $state=Get-GeoProfileAvailability $temp 'eu-primary' $report
    Assert ($state.Ready -and $state.State -eq 'attention' -and $state.Reason -match 'CAPTCHA') 'Challenge is selectable with an explicit warning'
    $hostsPath=Join-Path $temp 'hosts-test'
    [IO.File]::WriteAllText($hostsPath,"# BEGIN CHATGPT-US-WINDOWS`r`n"+$geminiText+"# END CHATGPT-US-WINDOWS`r`n")
    Assert ((Get-GeoHomeState $temp $report $hostsPath).State -eq 'attention') 'Active challenge is not shown as fully healthy'
    $eu.GeminiChallenge=$false;$eu.GeminiReady=$false
    $partial=Get-GeoProfileAvailability $temp 'eu-primary' $report
    Assert ($partial.Ready -and $partial.State -eq 'attention' -and $partial.Reason -match 'Gemini') 'A Gemini outage is explicit without disconnecting a working ChatGPT route'
    $eu.GeminiReady=$true;$eu.CheckedAt=(Get-Date).AddMinutes(-10).ToString('o')
    Assert (-not (Get-GeoProfileAvailability $temp 'eu-primary' $report).Ready) 'Stale probe does not unlock a shared profile'
    $stale=Get-GeoProfileAvailability $temp 'eu-primary' $report
    Assert ([regex]::Matches($stale.Reason,'проверка устарела').Count -eq 1) 'Shared services do not duplicate the same stale-node warning'
    $eu.CheckedAt=(Get-Date).ToString('o');$eu.EligibleEU=$true;$eu.FilesTLS=$true;$eu.FilesHTTP=404;$eu.GeminiReady=$false
    $us=[pscustomobject]@{Region='US';Address=$settings.us;SourceActive=$true;CheckedAt=(Get-Date).ToString('o');EligibleUS=$true}
    Assert (Get-GeoSelection $settings ([pscustomobject]@{rows=@($us,$eu)})).ready 'A shared route remains usable for ChatGPT when Gemini alone fails'
    $eu.GeminiReady=$true;$eu.GeminiChallenge=$true;$settings.eu=$eu.Address
    $good=[pscustomobject]@{Region='EU';Address='31.25.239.132';SourceActive=$true;CheckedAt=(Get-Date).ToString('o');EligibleEU=$true;GeminiReady=$true;GeminiChallenge=$false;FilesTLS=$true;FilesHTTP=404}
    Assert ((Get-GeoSelection $settings ([pscustomobject]@{rows=@($us,$eu,$good)})).eu -eq $good.Address) 'Automatic selection moves off a challenged current node when an unchallenged route exists'
    Write-Output 'Gemini checks passed: exact verification host, shared profiles, same-IP routing, real challenge-page transport, auto replacement, failures and stale probes.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-gemini-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
