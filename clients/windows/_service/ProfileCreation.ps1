. (Join-Path $PSScriptRoot 'GeoServices.ps1')
function Convert-GeoProfileAddress([string]$Text) {
    $address=$null
    if (-not [Net.IPAddress]::TryParse($Text,[ref]$address)) { throw ('Некорректный IP-адрес: '+$Text) }
    if ($address.IsIPv4MappedToIPv6) { $address=$address.MapToIPv4() }
    if ([Net.IPAddress]::IsLoopback($address)) { throw 'Адрес сервера не может быть loopback.' }
    $bytes=$address.GetAddressBytes()
    if ($address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        if ($bytes[0] -in @(0,10,127) -or $bytes[0] -ge 224 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)) { throw ('Нужен публичный адрес сервера: '+$Text) }
    } else {
        if ($address.Equals([Net.IPAddress]::IPv6Any) -or $address.IsIPv6LinkLocal -or $address.IsIPv6Multicast -or $address.IsIPv6SiteLocal -or (($bytes[0] -band 254) -eq 252)) { throw ('Нужен публичный адрес сервера: '+$Text) }
    }
    return $address.ToString().ToLowerInvariant()
}
function New-GeoServiceHosts([string]$Address,[ValidateSet('ChatGPT','Gemini')][string]$Service) {
    if([string]::IsNullOrWhiteSpace($Address)){throw 'Введите IP-адрес сервера.'}
    $ip=Convert-GeoProfileAddress $Address.Trim()
    $domains=if($Service -eq 'Gemini'){@(Get-GeoGeminiDomains)}else{@(
        'ab.chatgpt.com'
        'android.chat.openai.com'
        'api.openai.com'
        'auth.openai.com'
        'auth0.openai.com'
        'bps.openai.com'
        'cdn.oaistatic.com'
        'cdn.platform.openai.com'
        'chat.openai.com'
        'chatgpt.com'
        'codex-cloud-backend.chatgpt.com'
        'codex-cloud-environments.chatgpt.com'
        'developers.openai.com'
        'files.oaiusercontent.com'
        'ios.chat.openai.com'
        'oaistatic.com'
        'oaiusercontent.com'
        'openai.com'
        'operator.chatgpt.com'
        'platform.openai.com'
        'sdmntprcentralus.oaiusercontent.com'
        'sdmntpreastus2.oaiusercontent.com'
        'sdmntpritalynorth.oaiusercontent.com'
        'sdmntprnortheu.oaiusercontent.com'
        'sdmntprpolandcentral.oaiusercontent.com'
        'sdmntprsouthcentralus.oaiusercontent.com'
        'sdmntprukwest.oaiusercontent.com'
        'sdmntprwestcentralus.oaiusercontent.com'
        'sdmntprwestus.oaiusercontent.com'
        'tcr9i.chat.openai.com'
        'videos.openai.com'
        'webrtc.chatgpt.com'
        'ws.chatgpt.com'
        'www.chatgpt.com'
        'www.oaistatic.com'
        'www.oaiusercontent.com'
        'www.openai.com'
    )}
    return ((@('# '+$Service+' profile created by GeoRoute')+@($domains|ForEach-Object {$ip+' '+$_})) -join "`r`n")+"`r`n"
}
