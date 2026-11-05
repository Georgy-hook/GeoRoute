# Shared, deliberately narrow Gemini allowlist. Source: GeoHide's Google Gemini AI section.
# Do not route google.com, accounts.google.com or whole Google API/storage zones.
function Get-GeoGeminiDomains {
    return @('gemini.google.com','gemini.google','bard.google.com',
        'geminiweb-pa.clients.google.com','geminiweb-pa.clients6.google.com',
        'generativelanguage.googleapis.com','geller-pa.googleapis.com',
        'proactivebackend-pa.googleapis.com','robinfrontend-pa.googleapis.com')
}
function Test-GeoGeminiDomain([string]$Domain) {
    return $Domain.ToLowerInvariant() -in @(Get-GeoGeminiDomains)
}
function Test-GeoGeminiProbe($Page,$API) {
    $pageOk=$Page.tls -and ($Page.http -eq 200 -or ($Page.http -in @(301,302,303,307,308) -and ($Page.location -match '^https://accounts\.google\.com/' -or $Page.location -match '^https://www\.google\.com/sorry/')))
    return [bool]($pageOk -and -not $Page.blocked -and $API.tls -and $API.http -in @(200,204,400,401,404,405))
}
