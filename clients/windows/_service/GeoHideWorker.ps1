#Requires -Version 5.1
param([string]$ResultPath,[switch]$RefreshSources,[string]$RunId=([guid]::NewGuid().ToString('N')))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GeoHide.ps1')
. (Join-Path $PSScriptRoot 'GeoMonitorState.ps1')
. (Join-Path $PSScriptRoot 'GeoProbe.ps1')
if(Test-Path (Join-Path $PSScriptRoot 'Warp.ps1')){. (Join-Path $PSScriptRoot 'Warp.ps1')}
$settings=Read-GeoSettings $PSScriptRoot
$catalogPath=Join-Path $PSScriptRoot 'geohide-servers.json'
$catalog=Read-GeoCatalog $PSScriptRoot
$errors=@()
$initial=New-GeoPendingReport (@($catalog.servers)+@($settings.manualServers)) $RunId $(if($RefreshSources){'Обновляю списки GeoHide'}else{'Проверяю серверы'})
Write-GeoJson $ResultPath $initial
if($RefreshSources){
    foreach($source in $catalog.sources){
        if($source.disabled){continue}
        try{
            $text=(Invoke-WebRequest -UseBasicParsing -Uri $source.url -TimeoutSec 15).Content
            $addresses=@([regex]::Matches($text,'(?m)^([0-9.]+)\s+chatgpt\.com\s*(?:#.*)?$')|ForEach-Object{$_.Groups[1].Value}|Where-Object{Test-GeoAddress $_}|Sort-Object -Unique)
            if($addresses.Count -lt 1 -or $addresses.Count -gt 32){throw 'Нет достоверного списка chatgpt.com.'}
            Set-GeoRegionCatalog $catalog $source.region $addresses $source.url
            $source.checkedAt=(Get-Date).ToString('o')
        }catch{$errors+=($source.region+': '+$_.Exception.Message)}
    }
    Write-GeoJson $catalogPath $catalog
}
$adapter=Get-NetIPConfiguration|Where-Object{$_.IPv4DefaultGateway -and $_.InterfaceAlias -notmatch 'tun|vpn|wintun'}|Select-Object -First 1
if(-not $adapter){throw 'Не найден физический интерфейс с IPv4-шлюзом.'}
$ifIndex=[int]$adapter.InterfaceIndex
$localAddress=[string]$adapter.IPv4Address[0].IPAddress
$physicalIndex=$ifIndex;$physicalAddress=$localAddress
$preflight=[Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Stream,[Net.Sockets.ProtocolType]::Tcp)
try{
    $preflight.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31,[int][Net.IPAddress]::HostToNetworkOrder([int]$ifIndex))
    if([int]$preflight.GetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31) -ne $ifIndex){throw 'Не удалось привязать диагностику к физическому интерфейсу.'}
}finally{$preflight.Dispose()}

$servers=@(@($catalog.servers)+@($settings.manualServers)|Where-Object {(Test-GeoAddress $_.address) -and -not (Test-GeoClosedNode $_.region $_.address)}|Sort-Object region,address -Unique)
$warp=$null
if(Get-Command Sync-WarpCatalogue -ErrorAction SilentlyContinue){try{$warp=Sync-WarpCatalogue @($servers|ForEach-Object address)}catch{$errors+='WARP: '+$_.Exception.Message}}
$nativeAsset=Probe-GeoAsset
$report=New-GeoPendingReport $servers $RunId
$report.interface=$adapter.InterfaceAlias;$report.sources=$catalog.sources;$report.sourceErrors=$errors
$report|Add-Member NoteProperty networkNote 'Проверка привязана к IPv4-интерфейсу. Включённый VPN/TUN всё равно может влиять на результат. После смены сети повторите проверку.'
Write-GeoJson $ResultPath $report
foreach($row in $report.rows){
    $ifIndex=$physicalIndex;$localAddress=$physicalAddress
    if($warp -and $warp.Connected -and $row.Address -in @($warp.RouteAddresses)){$ifIndex=[int]$warp.InterfaceIndex;$localAddress=[string]$warp.LocalAddress}
    $row|Add-Member NoteProperty Transport $(if($ifIndex -eq $physicalIndex){'Physical'}else{'Warp'}) -Force
    $row.CheckState='Checking';$row.State='Проверяю ChatGPT, вложения и Gemini'
    $report.phase=$row.Region+' '+$row.Address
    Write-GeoJson $ResultPath $report
    $chat=Probe-Geo $row.Address 'chatgpt.com' '/cdn-cgi/trace'
    $files=Probe-Geo $row.Address 'files.oaiusercontent.com' '/'
    # Probe Gemini independently: a ChatGPT failure must not suppress Gemini diagnostics.
    $gemini=Probe-Geo $row.Address 'gemini.google.com' '/app'
    $api=if($gemini.tls){Probe-Geo $row.Address 'geminiweb-pa.clients6.google.com' '/'}else{[pscustomobject]@{tls=$false;http=$null;error='Gemini HTTPS недоступен'}}
    $asset=$nativeAsset
    $assetReady=$asset.tls -and $asset.http -in @(200,204,400,401,404,405)
    $challenge=$gemini.location -match '^https://www\.google\.com/sorry/'
    $verification=if($gemini.tls){Probe-Geo $row.Address 'www.google.com' '/sorry/'}else{$null}
    $filesReady=$files.tls -and $files.http -in @(200,204,301,302,400,401,404,405)
    $ready=$chat.tls -and $chat.http -eq 200 -and $chat.country
    $row.TCP=$chat.tcp;$row.TLS=$chat.tls;$row.HTTP=$chat.http;$row.Country=$chat.country;$row.LatencyMs=$chat.ms
    $row.FilesTLS=$files.tls;$row.FilesHTTP=$files.http;$row.Error=$chat.error
    $row.EligibleUS=[bool]($ready -and $chat.country -eq 'US')
    $row.EligibleRU=[bool]($ready -and $filesReady)
    $row.EligibleEU=[bool]($ready -and $filesReady -and $chat.country -in @('AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IE','IT','LV','LT','LU','MT','NL','PL','PT','RO','SK','SI','ES','SE','GB','CH','NO','IS'))
    $row.GeminiTLS=$gemini.tls;$row.GeminiHTTP=$gemini.http;$row.GeminiAPIHTTP=$api.http
    $row.GeminiAssetTLS=[bool]$asset.tls;$row.GeminiAssetHTTP=$asset.http
    $row.GeminiVerificationTLS=[bool]($verification -and $verification.tls)
    $row.GeminiVerificationHTTP=if($verification){$verification.http}else{$null}
    $row.GeminiReady=(Test-GeoGeminiProbe $gemini $api $verification) -and $assetReady
    $row.GeminiChallenge=[bool]$challenge
    if(($gemini.tcp -or $chat.tcp) -and ($challenge -or -not $row.GeminiReady -or -not $row.GeminiVerificationTLS)){
        $python=Join-Path $PSScriptRoot 'bridge\python\python.exe'
        if(Test-Path -LiteralPath $python){try{
            $raw=& $python -I (Join-Path $PSScriptRoot 'gemini_probe.py') --address $row.Address --interface-index $ifIndex --local-address $localAddress
            if($LASTEXITCODE -eq 0){
                $shared=$raw|ConvertFrom-Json
                $row.GeminiSharedHTTP2=[bool]($shared.ready -and $shared.verification)
                $row.GeminiRouteMs=$shared.ms;$row.GeminiCountry=$shared.country
                if($row.GeminiSharedHTTP2){
                    if(-not $api.tls){$api=Probe-Geo $row.Address 'geminiweb-pa.clients6.google.com' '/';$row.GeminiAPIHTTP=$api.http}
                    $row.GeminiReady=[bool]($api.tls -and $api.http -in @(200,204,400,401,404,405) -and $assetReady)
                    $row.GeminiChallenge=$false;$row.GeminiHTTP=$shared.http
                }
            }
        }catch{}}
    }
    $row.GeminiError=if($row.GeminiReady -and (-not $challenge -or $row.GeminiSharedHTTP2)){''}elseif($gemini.tls -and -not $assetReady){'Ресурсы Gemini: gemini.gstatic.com не прошёл HTTPS-проверку'}elseif($row.GeminiSharedHTTP2){'Gemini и Google открываются, но API / ресурсы не прошли проверку'}elseif($challenge -and -not $row.GeminiReady){'Gemini перенаправляет на Google, но общий маршрут проверки не прошёл тест. Выберите другой сервер.'}elseif($challenge){'Google ограничил доступ. Откройте Gemini после подключения; если есть CAPTCHA, пройдите её. Если поля нет, выберите другой сервер.'}elseif($gemini.blocked){'Страница ограничения региона'}elseif($gemini.error){$gemini.error}elseif($api.error){$api.error}elseif(-not $row.GeminiReady){'Страница / API Gemini не прошли HTTPS-проверку'}else{''}
    $row.State=if($ready){'ChatGPT: HTTPS отвечает'}elseif($chat.tcp){'ChatGPT: только TCP'}else{'ChatGPT: нет ответа'}
    $row.CheckedAt=(Get-Date).ToString('o');$row.CheckState='Complete'
    $report.completed++;$report.at=(Get-Date).ToString('o')
    Write-GeoJson $ResultPath $report
}
if($catalog.PSObject.Properties['retired']){foreach($node in $catalog.retired){
    if(@($servers|Where-Object {$_.region -eq $node.region -and $_.address -eq $node.address}).Count){continue}
    $reason=if($node.reason){$node.reason}else{'Адрес больше не публикуется источником'}
    $report.rows+=@([pscustomobject]@{Region=$node.region;Address=$node.address;SourceActive=$false;CheckState='Retired';State=$reason;TCP=$false;TLS=$false;HTTP=$null;Country='';LatencyMs=0;FilesTLS=$false;FilesHTTP=$null;Error=$reason;CheckedAt=(Get-Date).ToString('o');EligibleUS=$false;EligibleEU=$false;EligibleRU=$false;GeminiReady=$false})
}}
$report.running=$false;$report.phase='Проверка завершена';$report.at=(Get-Date).ToString('o')
Write-GeoJson $ResultPath $report
