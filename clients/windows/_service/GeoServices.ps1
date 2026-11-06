# Shared, deliberately narrow Gemini allowlist. Source: GeoHide's Google Gemini AI section.
# www.google.com must share Gemini's egress for Google's verification; this also routes Search.
# No google.com suffix rule, accounts.google.com, Gmail or whole Google API/storage zones.
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
    if($Node.PSObject.Properties['CheckedAt']){$at=[datetime]::MinValue;if(-not [datetime]::TryParse([string]$Node.CheckedAt,[ref]$at) -or ((Get-Date)-$at).TotalMinutes -ge 5){return $false}}
    return [bool](($Node.PSObject.Properties['GeminiVerificationTLS'] -and $Node.GeminiVerificationTLS -and $Node.GeminiVerificationHTTP -in @(200,204,400,429)) -or ($Node.PSObject.Properties['GeminiSharedHTTP2'] -and $Node.GeminiSharedHTTP2 -and $Node.GeminiReady))
}
function Test-GeoGeminiProbe($Page,$API,$Verification=$null) {
    if($Page.location -match '^https://www\.google\.com/sorry/' -and (-not $Verification -or -not $Verification.tls -or $Verification.http -notin @(200,400,429))){return $false}
    $pageOk=$Page.tls -and ($Page.http -eq 200 -or ($Page.http -in @(301,302,303,307,308) -and ($Page.location -match '^https://accounts\.google\.com/' -or $Page.location -match '^https://www\.google\.com/sorry/')))
    return [bool]($pageOk -and -not $Page.blocked -and $API.tls -and $API.http -in @(200,204,400,401,404,405))
}
