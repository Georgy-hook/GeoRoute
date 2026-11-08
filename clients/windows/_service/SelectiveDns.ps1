function Convert-DnsSite([string]$Text) {
 $value=$Text.Trim()
 if($value -match '://'){
  $uri=$null
  if(-not [uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo){throw 'Введите адрес сайта без логина и пароля.'}
  $value=$uri.DnsSafeHost
 }
 $value=([Globalization.IdnMapping]::new()).GetAscii($value.TrimEnd('.')).ToLowerInvariant()
 $ip=$null
 if($value.Length -gt 253 -or $value -notmatch '\.' -or [Net.IPAddress]::TryParse($value,[ref]$ip)){throw 'Введите домен сайта, например claude.ai.'}
 foreach($part in $value.Split('.')){if($part -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'){throw 'В домене не должно быть маски, порта или пробелов.'}}
 return $value
}
function Convert-DnsSiteList([string]$Text) {
 $sites=@($Text -split '[\s,;]+'|Where-Object {$_}|ForEach-Object {Convert-DnsSite $_}|Sort-Object -Unique)
 if($sites.Count -lt 1 -or $sites.Count -gt 100){throw 'Добавьте от 1 до 100 сайтов. Можно вставлять ссылки; пути будут убраны.'}
 return ,$sites
}
function New-SelectiveDnsConfig([string]$Url,[string[]]$Servers,[string[]]$Domains,[bool]$Subdomains=$true) {
 $uri=$null
 if(-not [uri]::TryCreate($Url.Trim(),[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'Для DNS нужен HTTPS DoH адрес без логина, query и нестандартного порта.'}
 $hostName=Convert-DnsSite $uri.DnsSafeHost
 $path=if($uri.AbsolutePath -eq '/'){'/dns-query'}else{$uri.AbsolutePath}
 if($path.Length -gt 512){throw 'Слишком длинный путь DoH.'}
 $sites=Convert-DnsSiteList ($Domains -join "`n")
 if(@($sites|Where-Object {$hostName -eq $_ -or ($Subdomains -and $hostName.EndsWith('.'+$_))}).Count){throw 'DNS-сервер не должен входить в список направляемых сайтов.'}
 $addresses=@(@(foreach($value in $Servers){if($value){Convert-GeoProfileAddress $value.Trim()}})|Select-Object -Unique)
 if($addresses.Count -gt 16){throw 'Не больше 16 bootstrap IP.'}
 return [pscustomobject]@{version=1;url=('https://'+$hostName+$path);servers=@($addresses);domains=@($sites);subdomains=$Subdomains}
}
function Read-SelectiveDnsConfig([string]$Root) {
 $path=Join-Path $Root 'selective-dns.json'
 if(Test-Path -LiteralPath $path){return (Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json)}
 return [pscustomobject]@{version=1;url='https://eu.geohide.ru/dns-query';servers=@('143.20.64.192','37.221.93.141','5.175.161.40','5.175.161.3');domains=@();subdomains=$true}
}
function Write-SelectiveDnsConfig([string]$Root,$Config) {
 $path=Join-Path $Root 'selective-dns.json'
 $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try {
  [IO.File]::WriteAllText($temp,($Config|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
  if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Get-SelectiveDnsNamespaces($Config) {
 return @(foreach($name in $Config.domains){$name;if($Config.subdomains){'.'+$name}})
}
function Test-DnsNamespaceOverlap([string]$Left,[string]$Right) {
 if($Left -eq '.' -or $Right -eq '.'){return $true}
 $l=$Left.TrimStart('.').ToLowerInvariant();$r=$Right.TrimStart('.').ToLowerInvariant()
 return ($l -eq $r -or ($Left.StartsWith('.') -and $r.EndsWith('.'+$l)) -or ($Right.StartsWith('.') -and $l.EndsWith('.'+$r)))
}
function Get-SelectiveDnsOwnRules {
 return @(Get-DnsClientNrptRule -ErrorAction Stop|Where-Object {$_.Comment -ceq 'GeoRoute selective DNS v1' -and (@($_.NameServers) -join ',') -eq '127.0.0.2'})
}
function Get-SelectiveDnsStatus {
 $service=Get-Service -Name GeoRouteDNS -ErrorAction SilentlyContinue
 if(-not $service){return [pscustomobject]@{Active=$false;Text='DNS для выбранных сайтов выключен';Count=0}}
 try {
  $rules=@(Get-SelectiveDnsOwnRules)
  $count=@($rules|ForEach-Object {$_.Namespace}|Where-Object {-not $_.StartsWith('.')}|Sort-Object -Unique).Count
  $active=$service.Status -eq 'Running' -and $count -gt 0
  $text=if($active){'Включён · '+$count+' сайтов · запуск с Windows'}elseif($count){'Требует внимания: правила включены, служба не работает'}else{'DNS для сайтов выключен'}
  $configPath=Join-Path $env:ProgramFiles 'GeoRoute DNS\config.json'
  if($active -and (Test-Path -LiteralPath $configPath)){
   $cfg=Get-Content $configPath -Raw -Encoding UTF8|ConvertFrom-Json
   $expected=@(Get-SelectiveDnsNamespaces $cfg)|Sort-Object
   $actual=@($rules|ForEach-Object {$_.Namespace})|Sort-Object
   if(($expected -join '|') -cne ($actual -join '|')){$active=$false;$text='Правила применены не полностью. Выключите DNS для сайтов или обновите подключение.'}
   else{
    $text+=' · '+([uri]$cfg.url).Host
    $statusPath=Join-Path $env:ProgramData 'GeoRouteDNS\status.json'
    if(Test-Path $statusPath){try{$state=Get-Content $statusPath -Raw -Encoding UTF8|ConvertFrom-Json;if($state.lastError){$text+=' · Последний DNS-запрос завершился ошибкой: '+$state.lastError}}catch{}}
   }
  }
  return [pscustomobject]@{Active=$active;Text=$text;Count=$count}
 } catch {return [pscustomobject]@{Active=$false;Text='Не удалось прочитать правила DNS; состояние не подтверждено';Count=0}}
}
function Assert-SelectiveDnsConflicts($Config,$Rules,[string]$HostsText) {
 $ours=Get-SelectiveDnsNamespaces $Config
 foreach($rule in $Rules){
  if($rule.PSObject.Properties['Comment'] -and $rule.Comment -ceq 'GeoRoute selective DNS v1' -and (@($rule.NameServers) -join ',') -eq '127.0.0.2'){continue}
  foreach($existing in @($rule.Namespace)){foreach($candidate in $ours){if(Test-DnsNamespaceOverlap $existing $candidate){throw ('Для '+$candidate+' уже есть другое DNS-правило. Оно сохранено; сначала устраните пересечение.')}}}
 }
 foreach($line in ($HostsText -split '\r?\n')){
  $parts=($line -split '#',2)[0].Trim() -split '\s+'
  if($parts.Count -lt 2){continue}
  foreach($name in $parts[1..($parts.Count-1)]){foreach($ns in $ours){if(Test-DnsNamespaceOverlap $ns $name.ToLowerInvariant()){throw ('Сайт '+$name+' уже задан в hosts. Выключите его hosts-профиль или удалите этот сайт из DNS-списка.')}}}
 }
}
