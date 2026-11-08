$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'ProfileCreation.ps1')
. (Join-Path $source 'SelectiveDns.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Reject($Block,$Message){$failed=$false;try{& $Block|Out-Null}catch{$failed=$true};Assert $failed $Message}
$sites=Convert-DnsSiteList "https://Claude.AI/chat/123`nclaude.ai`nhttps://пример.рф/page"
Assert ($sites.Count -eq 2 -and 'claude.ai' -in $sites -and 'xn--e1afmkfd.xn--p1ai' -in $sites) 'Normalize links and IDN without changing scope'
$cfg=New-SelectiveDnsConfig 'https://eu.geohide.ru/dns-query' @('143.20.64.192') @('claude.ai') $true
Assert ((@(Get-SelectiveDnsNamespaces $cfg) -join ',') -eq 'claude.ai,.claude.ai') 'Exact name and its suffix are explicit'
Assert-SelectiveDnsConflicts $cfg @() "127.0.0.1 localhost`n143.20.64.192 gemini.google.com"
Reject {Assert-SelectiveDnsConflicts $cfg @() '143.20.64.192 api.claude.ai'} 'Never silently ignore an overlapping hosts mapping'
Reject {Assert-SelectiveDnsConflicts $cfg @([pscustomobject]@{Namespace=@('.ai');NameServers='1.1.1.1'}) ''} 'Never overwrite a foreign NRPT suffix'
Reject {Assert-SelectiveDnsConflicts $cfg @([pscustomobject]@{Namespace=@('.');NameServers='1.1.1.1'}) ''} 'Root DNS policy is a conflict'
Assert-SelectiveDnsConflicts $cfg @([pscustomobject]@{Namespace=@('claude.ai','.claude.ai');NameServers='127.0.0.2';Comment='GeoRoute selective DNS v1'}) ''
Assert (-not (Test-DnsNamespaceOverlap '.claude.ai' 'claude.ai.evil.test')) 'Suffix matching must respect label boundaries'
Reject {New-SelectiveDnsConfig 'http://eu.geohide.ru/' @() @('claude.ai')} 'No plaintext DNS upstream'
Reject {New-SelectiveDnsConfig 'https://eu.geohide.ru/?token=secret' @() @('claude.ai')} 'No embedded credentials/query'
Reject {New-SelectiveDnsConfig 'https://eu.geohide.ru/' @() @('geohide.ru')} 'No recursive resolver bootstrap'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-sites-'+[guid]::NewGuid().ToString('N'))
try{
 [IO.Directory]::CreateDirectory($temp)|Out-Null
 Write-SelectiveDnsConfig $temp $cfg
 $saved=Read-SelectiveDnsConfig $temp
 Assert ($saved.domains[0] -eq 'claude.ai' -and $saved.url -eq $cfg.url -and $saved.subdomains) 'Selected sites persist independently of system DNS'
}finally{if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
Write-Output 'Selected DNS: scoped namespaces, URL/IDN validation, foreign policies, hosts conflicts and local persistence passed; network unchanged.'
