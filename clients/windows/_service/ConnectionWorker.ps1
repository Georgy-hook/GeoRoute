#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Connection.ps1')
. (Join-Path $PSScriptRoot 'HttpProxy.ps1')
$proxyState=Get-HttpProxyState $PSScriptRoot
if($proxyState.Enabled){
    $check=Test-ChatGptHttpProxy $proxyState.Server
    $report=[pscustomobject]@{Mode='http-proxy';State=$(if($check.Ok){'ready'}else{'unavailable'});Title=$(if($check.Ok){'ChatGPT отвечает через US-прокси'}else{'US-прокси требует проверки'});Next=($check.Message+' Настройка Windows сохраняется без менеджера. Конкретные вложения и сеанс управления проверяются внутри Dot.');At=$check.At;Checks=@();Server=$check.Server;Country=$check.Country;AttachmentsVerified=$false}
    $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 0
}
# Wildcard DNS rewrites belong to the optional NextDNS Bridge. In hosts mode
# they are neither expected nor a reason to show a permanent warning.
$bridge=Get-Service -Name NextDNSBridge -ErrorAction SilentlyContinue
$hostsText=Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -Raw -ErrorAction Stop
if(Test-ConnectionHostsMode $hostsText ([bool]($bridge -and $bridge.Status -eq 'Running'))) {
    . (Join-Path $PSScriptRoot 'GeoHide.ps1')
    . (Join-Path $PSScriptRoot 'Home.ps1')
    $snapshotPath=Join-Path $PSScriptRoot 'geohide-monitor.json'
    $snapshot=if(Test-Path -LiteralPath $snapshotPath){Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $home=Get-GeoHomeState $PSScriptRoot $snapshot
    $report=[pscustomobject]@{Mode='hosts';State=$home.State;Title=$home.Title;Next=$home.Detail;At=(Get-Date).ToString('o');Checks=@();AttachmentsVerified=$false}
    $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit 0
}
try {
    $config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'connection-routes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $nonce='manager-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $pending=@(foreach($route in $config.routes) {
        # A unique name tests inherited DNS routing without a cached or hosts-specific entry.
        [pscustomobject]@{Route=$route;Task=[Net.Dns]::GetHostAddressesAsync($nonce+'.'+$route.domain)}
    })
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(@($pending | Where-Object {-not $_.Task.IsCompleted}).Count -and $watch.Elapsed.TotalSeconds -lt 12) {Start-Sleep -Milliseconds 100}
    $checks=@(foreach($item in $pending) {
        $addresses=@();$state='unavailable'
        if($item.Task.Status -eq 'RanToCompletion') {
            $addresses=@($item.Task.Result | ForEach-Object {$_.IPAddressToString} | Sort-Object -Unique)
            if($addresses.Count) {$state=if(@($addresses|Where-Object {$_ -notin $item.Route.addresses}).Count -eq 0){'ready'}else{'mismatch'}}
        }
        [pscustomobject]@{Domain=$item.Route.domain;Label=$item.Route.label;State=$state;Addresses=$addresses;Expected=@($item.Route.addresses)}
    })
    $report=New-ConnectionReport $checks -ExpectedCount @($config.routes).Count
} catch {$report=New-ConnectionReport @()}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
