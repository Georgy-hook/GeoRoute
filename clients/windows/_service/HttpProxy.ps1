#Requires -Version 5.1
# This policy is consumed by Chromium/Electron directly; it needs no local HTTP server.
function ConvertTo-ChatGptProxyEndpoint([string]$Server) {
    if($Server -cnotmatch '^((?:\d{1,3}\.){3}\d{1,3}):([1-9]\d{0,4})$'){throw 'Введите IPv4 и порт вашего HTTP-прокси.'}
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Matches[1],[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Некорректный IPv4.'}
    $port=[int]$Matches[2];$bytes=$ip.GetAddressBytes()
    if($port -gt 65535 -or $bytes[0] -eq 0 -or $bytes[0] -eq 10 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)){throw 'Нужны публичный IPv4 и порт 1–65535.'}
    [pscustomobject]@{Host=$ip.ToString();Port=$port;Server=($ip.ToString()+':'+$port)}
}
function Get-ChatGptProxyPac([string]$Server) {
    $endpoint=ConvertTo-ChatGptProxyEndpoint $Server
    @'
function FindProxyForURL(url, host) {
  host = host.toLowerCase();
  if (host.charAt(host.length - 1) === ".") host = host.slice(0, -1);
  var roots = ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"];
  for (var i = 0; i < roots.length; i++) {
    var root = roots[i];
    if (host === root || host.slice(-(root.length + 1)) === "." + root)
      return "PROXY __SERVER__";
  }
  return "DIRECT";
}
'@.Replace('__SERVER__',$endpoint.Server)
}
function Get-ChatGptProxyDataUrl([string]$Server) {
    'data:application/x-ns-proxy-autoconfig;base64,'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-ChatGptProxyPac $Server)))
}
function Send-ProxySettingsChanged {
    if(-not ('NextDNSProxySettingsNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NextDNSProxySettingsNative {
 [DllImport("wininet.dll", SetLastError=true)]
 public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
'@
    }
    [void][NextDNSProxySettingsNative]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
    [void][NextDNSProxySettingsNative]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
}
function Get-HttpProxyState([string]$Root) {
    $path=Join-Path $Root 'state\http-proxy.json'
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{Enabled=$false;Server='';Text='US-прокси выключен';Verified=$false}}
    try {
        $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $actual=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings','AutoConfigURL',$null)
        $enabled=[bool]$state.Enabled -and $actual -ceq $state.PacUrl
        [pscustomobject]@{Enabled=$enabled;Server=[string]$state.Server;Text=$(if($enabled){'US HTTP-прокси включён: '+$state.Server}else{'US-прокси выключен или изменён вне менеджера'});Verified=$false}
    } catch {[pscustomobject]@{Enabled=$false;Server='';Text='Не удалось прочитать настройку US-прокси';Verified=$false}}
}
function Set-ChatGptHttpProxy([string]$Root,[string]$Server) {
    $endpoint=ConvertTo-ChatGptProxyEndpoint $Server
    $pac=Get-ChatGptProxyDataUrl $endpoint.Server
    $folder=Join-Path $Root 'state';[IO.Directory]::CreateDirectory($folder)|Out-Null
    if((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка настроек не должна быть ссылкой.'}
    $path=Join-Path $folder 'http-proxy.json'
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$true)
    try {
        $beforeUrl=$key.GetValue('AutoConfigURL',$null)
        $old=$null
        if(Test-Path -LiteralPath $path){$old=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}
        if([int]$key.GetValue('ProxyEnable',0) -ne 0){throw 'Уже включён другой системный прокси. Его настройки не заменены.'}
        if($beforeUrl -and (-not $old -or $beforeUrl -cne $old.PacUrl)){throw 'Уже настроен другой PAC. Его настройки не заменены.'}
        $backup=if($old -and $old.Enabled -and $beforeUrl -ceq $old.PacUrl){$old.Backup}else{@{HadAutoConfigURL=($null -ne $beforeUrl);AutoConfigURL=$beforeUrl}}
        $state=[ordered]@{Version=1;Enabled=$true;Server=$endpoint.Server;PacUrl=$pac;At=(Get-Date).ToString('o');Backup=$backup}
        # Save the undo information before changing Windows.
        $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($path+'.tmp') -Destination $path -Force
        [IO.File]::WriteAllText((Join-Path $folder 'chatgpt.pac'),(Get-ChatGptProxyPac $endpoint.Server),[Text.UTF8Encoding]::new($false))
        $key.SetValue('AutoConfigURL',$pac,[Microsoft.Win32.RegistryValueKind]::String)
    } finally {$key.Dispose()}
    Send-ProxySettingsChanged
    Get-HttpProxyState $Root
}
function Remove-ChatGptHttpProxy([string]$Root) {
    $path=Join-Path $Root 'state\http-proxy.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$true)
    try {
        if($key.GetValue('AutoConfigURL',$null) -ceq $state.PacUrl){
            if($state.Backup.HadAutoConfigURL){$key.SetValue('AutoConfigURL',[string]$state.Backup.AutoConfigURL,[Microsoft.Win32.RegistryValueKind]::String)}else{$key.DeleteValue('AutoConfigURL',$false)}
        }
        $state.Enabled=$false;$state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $path -Encoding UTF8
    } finally {$key.Dispose()}
    Send-ProxySettingsChanged
}
function Test-ChatGptHttpProxy([string]$Server) {
    $endpoint=ConvertTo-ChatGptProxyEndpoint $Server
    $request=[Net.HttpWebRequest]::Create('https://chatgpt.com/cdn-cgi/trace')
    $request.Proxy=[Net.WebProxy]::new(('http://'+$endpoint.Server),$false)
    $request.Timeout=10000;$request.ReadWriteTimeout=10000;$request.AllowAutoRedirect=$false
    $request.UserAgent='NextDNS-Connection-Manager/1.0';$response=$null
    try {
        $response=$request.GetResponse()
        $reader=[IO.StreamReader]::new($response.GetResponseStream());$buffer=New-Object char[] 8192
        try {$count=$reader.ReadBlock($buffer,0,$buffer.Length);$body=[string]::new($buffer,0,$count)}finally{$reader.Dispose()}
        $country=if($body -match '(?m)^loc=([A-Z]{2})\r?$'){$Matches[1]}else{''}
        [pscustomobject]@{At=(Get-Date).ToString('o');Server=$endpoint.Server;Ok=([int]$response.StatusCode -eq 200 -and $country -eq 'US');Country=$country;Http=[int]$response.StatusCode;Message=$(if($country -eq 'US'){'HTTPS проверен. ChatGPT видит выход US.'}else{'HTTPS ответил, но выход US не подтверждён.'});AttachmentsVerified=$false}
    } catch {[pscustomobject]@{At=(Get-Date).ToString('o');Server=$endpoint.Server;Ok=$false;Country='';Http=0;Message=('Прокси не прошёл HTTPS-проверку: '+$_.Exception.Message);AttachmentsVerified=$false}} finally {if($response){$response.Dispose()}}
}
