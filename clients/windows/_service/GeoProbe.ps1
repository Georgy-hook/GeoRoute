function Probe-Geo($Address,$HostName,$Path) {
    $result=[ordered]@{tcp=$false;tls=$false;http=$null;country='';ms=0;error='';location='';blocked=$false}
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
        $request=[Text.Encoding]::ASCII.GetBytes("GET $Path HTTP/1.1`r`nHost: $HostName`r`nConnection: close`r`nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36`r`n`r`n")
        $stream.Write($request,0,$request.Length)
        $buffer=New-Object byte[] 8192;$body=''
        try{while($body.Length -lt 32768){$n=$stream.Read($buffer,0,$buffer.Length);if($n -eq 0){break};$body+=[Text.Encoding]::UTF8.GetString($buffer,0,$n)}}catch{if(-not $body){throw}}
        if($body -match '^HTTP/\S+\s+(\d+)'){$result.http=[int]$Matches[1]}
        if($body -match '(?im)^Location:\s*([^\r\n]+)'){$result.location=$Matches[1].Trim()}
        $result.blocked=($result.location -match '^https://gemini\.google\.com/(?:unsupported|unavailable)' -or $body -match '(?i)Gemini isn.t (?:currently )?(?:available|supported)|not available in your country|not supported in your country')
        if($body -match '(?m)^loc=([A-Z]{2})'){$result.country=$Matches[1]}
    }catch{$result.error=$_.Exception.GetBaseException().Message}
    finally{if($stream){$stream.Dispose()};if($socket){$socket.Dispose()};$result.ms=$watch.ElapsedMilliseconds}
    return [pscustomobject]$result
}
