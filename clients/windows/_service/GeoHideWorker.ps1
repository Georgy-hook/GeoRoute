#Requires -Version 5.1
param([string]$ResultPath,[switch]$RefreshSources)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GeoHide.ps1')
$settings=Read-GeoSettings $PSScriptRoot
$catalogPath=Join-Path $PSScriptRoot 'geohide-servers.json'
$catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json
$errors=@()
if($RefreshSources){
    foreach($source in $catalog.sources){
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
$preflight=[Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Stream,[Net.Sockets.ProtocolType]::Tcp)
try{
    $preflight.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31,[int][Net.IPAddress]::HostToNetworkOrder([int]$ifIndex))
    if([int]$preflight.GetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31) -ne $ifIndex){throw 'Не удалось привязать диагностику к физическому интерфейсу.'}
}finally{$preflight.Dispose()}

function Probe-Geo($Address,$HostName,$Path) {
    $result=[ordered]@{tcp=$false;tls=$false;http=$null;country='';ms=0;error=''}
    $watch=[Diagnostics.Stopwatch]::StartNew();$socket=$null;$stream=$null
    try{
        $socket=[Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Stream,[Net.Sockets.ProtocolType]::Tcp)
        $socket.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP,[Net.Sockets.SocketOptionName]31,[int][Net.IPAddress]::HostToNetworkOrder([int]$ifIndex))
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Parse($localAddress),0))
        $pending=$socket.BeginConnect($Address,443,$null,$null)
        try{if(-not $pending.AsyncWaitHandle.WaitOne(1800)){throw 'TCP timeout'};$socket.EndConnect($pending)}finally{$pending.AsyncWaitHandle.Close()}
        $result.tcp=$true
        $net=[Net.Sockets.NetworkStream]::new($socket,$false);$net.ReadTimeout=2200;$net.WriteTimeout=2200
        $stream=[Net.Security.SslStream]::new($net,$false)
        $handshake=$stream.BeginAuthenticateAsClient($HostName,$null,$null)
        try{if(-not $handshake.AsyncWaitHandle.WaitOne(2500)){throw 'TLS timeout'};$stream.EndAuthenticateAsClient($handshake)}finally{$handshake.AsyncWaitHandle.Close()}
        $result.tls=$true;$stream.ReadTimeout=2200
        $request=[Text.Encoding]::ASCII.GetBytes("GET $Path HTTP/1.1`r`nHost: $HostName`r`nConnection: close`r`nUser-Agent: GeoHide-Monitor/1.0`r`n`r`n")
        $stream.Write($request,0,$request.Length)
        $buffer=New-Object byte[] 8192;$body=''
        try{while($body.Length -lt 32768){$n=$stream.Read($buffer,0,$buffer.Length);if($n -eq 0){break};$body+=[Text.Encoding]::UTF8.GetString($buffer,0,$n)}}catch{if(-not $body){throw}}
        if($body -match '^HTTP/\S+\s+(\d+)'){$result.http=[int]$Matches[1]}
        if($body -match '(?m)^loc=([A-Z]{2})'){$result.country=$Matches[1]}
    }catch{$result.error=$_.Exception.GetBaseException().Message}
    finally{if($stream){$stream.Dispose()};if($socket){$socket.Dispose()};$result.ms=$watch.ElapsedMilliseconds}
    return [pscustomobject]$result
}
$rows=@();$servers=@($catalog.servers)+@($settings.manualServers)
foreach($server in @($servers|Sort-Object region,address -Unique)){
    if(-not (Test-GeoAddress $server.address)){continue}
    $chat=Probe-Geo $server.address 'chatgpt.com' '/cdn-cgi/trace'
    $files=if($chat.tcp){Probe-Geo $server.address 'files.oaiusercontent.com' '/'}else{[pscustomobject]@{tls=$false;http=$null;error='TCP недоступен'}}
    $filesReady=$files.tls -and $files.http -in @(200,204,301,302,400,401,404,405)
    $ready=$chat.tls -and $chat.http -eq 200 -and $chat.country
    $state=if($ready){'HTTPS работает'}elseif($chat.tcp){'TCP есть, HTTPS не работает'}else{'Недоступен с вашего подключения'}
    $rows+=[pscustomobject]@{Region=$server.region;Address=$server.address;SourceActive=$true;State=$state;TCP=$chat.tcp;TLS=$chat.tls;HTTP=$chat.http;Country=$chat.country;LatencyMs=$chat.ms;FilesTLS=$files.tls;FilesHTTP=$files.http;Error=$chat.error;CheckedAt=(Get-Date).ToString('o');EligibleUS=($ready -and $chat.country -eq 'US');EligibleRU=($ready -and $filesReady);EligibleEU=($ready -and $filesReady -and $chat.country -in @('AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IE','IT','LV','LT','LU','MT','NL','PL','PT','RO','SK','SI','ES','SE','GB','CH','NO','IS'))}
    Write-GeoJson $ResultPath ([ordered]@{running=$true;at=(Get-Date).ToString('o');interface=$adapter.InterfaceAlias;rows=$rows;sourceErrors=$errors;sources=$catalog.sources})
}
if($catalog.PSObject.Properties['retired']){foreach($node in $catalog.retired){
    if(@($servers|Where-Object {$_.region -eq $node.region -and $_.address -eq $node.address}).Count){continue}
    $rows+=@([pscustomobject]@{Region=$node.region;Address=$node.address;SourceActive=$false;State='Удалён из списка GeoHide';TCP=$false;TLS=$false;HTTP=$null;Country='';LatencyMs=0;FilesTLS=$false;FilesHTTP=$null;Error='Адрес больше не публикуется источником';CheckedAt=(Get-Date).ToString('o');EligibleUS=$false;EligibleEU=$false;EligibleRU=$false})
}}
Write-GeoJson $ResultPath ([ordered]@{running=$false;at=(Get-Date).ToString('o');interface=$adapter.InterfaceAlias;rows=$rows;sourceErrors=$errors;sources=$catalog.sources})
