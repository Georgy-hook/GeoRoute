#Requires -Version 5.1
$script:warpObservationState=$null
$script:warpObservationAt=[datetime]::MinValue
function Get-WarpPaths {
 $root=Join-Path $env:ProgramData 'GeoRouteWarp'
 [pscustomobject]@{Root=$root;Public=(Join-Path $root 'public');Requests=(Join-Path $root 'requests');Program=(Join-Path $env:ProgramFiles 'GeoRoute WARP')}
}
function Get-WarpState {
 $paths=Get-WarpPaths
 $state=[ordered]@{Installed=$false;CanControl=$false;Connected=$false;Requested=$false;AutoStart=$false;State='not-installed';Error='';ProfileName='';ProfileId='';Addresses=@();RouteAddresses=@();RoutesCommandId='';Country='';InterfaceIndex=$null;LocalAddress=$null;CommandId=''}
 try{
  $service=Get-Service -Name GeoRouteWARP -ErrorAction SilentlyContinue
  if(-not $service){return [pscustomobject]$state}
  $state.Installed=$true
  $owner=Get-Content -Raw -LiteralPath (Join-Path $paths.Public 'owner.json') -Encoding UTF8|ConvertFrom-Json
  $state.CanControl=([string]$owner.ownerSid -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
  $value=Get-Content -Raw -LiteralPath (Join-Path $paths.Public 'status.json') -Encoding UTF8|ConvertFrom-Json
  foreach($key in @('Connected','Requested','AutoStart','State','Error','ProfileName','ProfileId','Addresses','RouteAddresses','RoutesCommandId','Country','InterfaceIndex','LocalAddress','CommandId')){if($value.PSObject.Properties[$key]){$state[$key]=$value.$key}}
  if($service.Status -ne 'Running'){$state.Connected=$false;$state.State='controller-stopped'}
 }catch{$state.Connected=$false;$state.State='unknown';$state.Error='status_unavailable'}
 [pscustomobject]$state
}
function Test-WarpPreferred([string]$Root){
 try{$settings=Get-Content -Raw -LiteralPath (Join-Path $Root 'GUI-settings.json') -Encoding UTF8|ConvertFrom-Json;return $settings.WarpPreferred -eq $true}catch{return $false}
}
function Test-WarpObservationContext($Node){
 if(-not $script:warpObservationState -or ((Get-Date)-$script:warpObservationAt).TotalSeconds -ge 2){$script:warpObservationState=Get-WarpState;$script:warpObservationAt=Get-Date}
 $state=$script:warpObservationState
 $wasWarp=$Node.PSObject.Properties['Transport'] -and $Node.Transport -eq 'Warp'
 $isWarp=$state.Connected -and $Node.Address -in @($state.RouteAddresses)
 return [bool]($wasWarp -eq $isWarp)
}
function Get-WarpProfile([string]$Root,[string]$ProfileId){
 $catalog=Get-Content -Raw -LiteralPath (Join-Path $Root 'profiles.json') -Encoding UTF8|ConvertFrom-Json
 $entry=@($catalog.Profiles|Where-Object id -eq $ProfileId)
 if($entry.Count -ne 1){throw 'Выберите существующий профиль.'}
 $path=[IO.Path]::GetFullPath((Join-Path $Root ([string]$entry[0].hostsFile)))
 if(-not $path.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Некорректный путь профиля.'}
 $records=@()
 foreach($line in ([IO.File]::ReadAllText($path) -split '\r?\n')){
  $parts=@(($line -split '#',2)[0].Trim() -split '\s+')
  if($parts.Count -lt 2){continue}
  foreach($domain in @($parts|Select-Object -Skip 1)){
   if($domain.ToLowerInvariant() -eq 'gemini.gstatic.com'){continue}
   if($domain -notmatch '^(?:[a-z0-9-]+\.)*(?:chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$' -and $domain -notin @('gemini.google.com','gemini.google','bard.google.com','www.google.com','geminiweb-pa.clients.google.com','geminiweb-pa.clients6.google.com','generativelanguage.googleapis.com','geller-pa.googleapis.com','proactivebackend-pa.googleapis.com','robinfrontend-pa.googleapis.com')){throw 'Этот профиль содержит другие сайты. Режим WARP пока поддерживает профили ChatGPT и Gemini.'}
   $ip=$null
   if(-not [Net.IPAddress]::TryParse($parts[0],[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork'){throw 'Для WARP нужен профиль с IPv4-адресами.'}
   $records+=@{domain=$domain.ToLowerInvariant();address=$parts[0]}
  }
 }
 @{id=[string]$entry[0].id;name=[string]$entry[0].name;map=$records}
}
function Invoke-WarpControl {
 param([ValidateSet('Connect','Disconnect','AutoOn','AutoOff')][string]$Mode,$Profile=$null,[int]$TimeoutSeconds=50)
 $state=Get-WarpState
 if(-not $state.Installed -or -not $state.CanControl){throw 'Компонент WARP не установлен для этой учётной записи.'}
 $command=@{Connect=128;Disconnect=129;AutoOn=130;AutoOff=131}[$Mode]
 $requestId=[guid]::NewGuid().ToString('N')
 if($Mode -eq 'Connect'){
  $paths=Get-WarpPaths
  $request=@{schema=1;id=$requestId;profile=$Profile}|ConvertTo-Json -Depth 12 -Compress
  if([Text.Encoding]::UTF8.GetByteCount($request) -gt 65536){throw 'В профиле слишком много адресов.'}
  $path=Join-Path $paths.Requests 'connect.json'
  foreach($candidate in @($paths.Root,$paths.Requests,$path)){if((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Папка команд не должна быть ссылкой.'}}
  $temp=Join-Path $paths.Requests ('request-'+$requestId+'.tmp')
  try{
   [IO.File]::WriteAllText($temp,$request,[Text.UTF8Encoding]::new($false))
   if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
  }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
 }
 $service=Get-Service -Name GeoRouteWARP
 try{
  if($service.Status -ne 'Running'){$service.Start();$service.WaitForStatus('Running',[timespan]::FromSeconds(15))}
  $service.ExecuteCommand($command)
 }finally{$service.Dispose()}
 $until=(Get-Date).AddSeconds($TimeoutSeconds)
 do{
  $current=Get-WarpState
  if($Mode -eq 'Connect' -and $current.CommandId -ceq $requestId){
   if($current.Connected){return $current}
   if($current.State -in @('retrying','cleanup-required')){throw (Get-WarpProblem $current.Error)}
  }
  if($Mode -eq 'Disconnect' -and -not $current.Requested -and $current.State -eq 'off'){return $current}
  if($Mode -eq 'AutoOn' -and $current.AutoStart){return $current}
  if($Mode -eq 'AutoOff' -and -not $current.AutoStart){return $current}
  Start-Sleep -Milliseconds 250
 }while((Get-Date) -lt $until)
 throw 'Служба не завершила действие вовремя. Состояние показано в настройках WARP.'
}
function Get-WarpTitle($State){
 switch($State.State){
  connected{'Подключено через WARP'}connecting{'Подключаю WARP…'}retrying{'Восстанавливаю подключение…'}disconnecting{'Отключаю WARP…'}off{'WARP выключен'}'not-installed'{'WARP ещё не установлен'}'controller-stopped'{'Контроллер WARP остановлен'}'cleanup-required'{'Нужно восстановление WARP'}default{'Состояние WARP недоступно'}
 }
}
function Get-WarpProblem([string]$Code){
 switch -Regex ($Code){
  'route_https_unavailable' {return 'GeoHide не прошёл HTTPS-проверку через WARP. Выберите другой сервер и повторите подключение.'}
  'existing_route_conflict|adapter_name_conflict' {return 'Есть конфликт с существующим маршрутом или адаптером. WARP не меняет чужие настройки; подробности в журнале.'}
  'physical_network_unavailable' {return 'Не найдено обычное подключение Ethernet или Wi-Fi. Проверьте подключение к интернету.'}
  'runtime_hash_mismatch' {return 'Проверка файлов WARP не пройдена. Переустановите компонент из настроек.'}
  'profile_changed_externally' {return 'Настройки hosts изменены вне WARP. Изменения сохранены; выберите нужный профиль перед подключением.'}
  'cleanup|ownership_missing' {return 'Не удалось полностью убрать собственные настройки WARP. Смотрите журнал перед повторным подключением.'}
  default {return 'WARP не завершил действие. Откройте журнал WARP и повторите подключение; код: '+$Code}
 }
}
function Sync-WarpCatalogue([string[]]$Addresses){
 $state=Get-WarpState
 if(-not $state.Installed -or -not $state.CanControl){return $state}
 $addresses=@($Addresses|Sort-Object -Unique)
 if($addresses.Count -gt 64){throw 'Слишком много адресов GeoHide.'}
 foreach($address in $addresses){$ip=$null;if(-not [Net.IPAddress]::TryParse($address,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $ip.ToString() -cne $address){throw 'Некорректный IPv4 GeoHide.'}}
 $paths=Get-WarpPaths;$id=[guid]::NewGuid().ToString('N');$path=Join-Path $paths.Requests 'routes.json';$temp=Join-Path $paths.Requests ('routes-'+$id+'.tmp')
 foreach($candidate in @($paths.Root,$paths.Requests,$path)){if((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Папка команд не должна быть ссылкой.'}}
 try{
  [IO.File]::WriteAllText($temp,(@{schema=1;id=$id;addresses=$addresses}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
 $service=Get-Service GeoRouteWARP
 try{if($service.Status -ne 'Running'){return $state};$service.ExecuteCommand(132)}finally{$service.Dispose()}
 $until=(Get-Date).AddSeconds(25)
 do{$state=Get-WarpState;if($state.RoutesCommandId -ceq $id){return $state};Start-Sleep -Milliseconds 250}while((Get-Date) -lt $until)
 throw 'Обновление маршрутов WARP не завершилось вовремя.'
}
function Initialize-WarpRuntime([string]$SourceRoot,[switch]$SkipBootstrap){
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $manifest=Get-Content -Raw -LiteralPath (Join-Path $SourceRoot 'warp-runtime.json') -Encoding UTF8|ConvertFrom-Json
 $cache=Join-Path $env:LOCALAPPDATA 'GeoRoute\warp-runtime-1.19.34'
 [IO.Directory]::CreateDirectory($cache)|Out-Null
 if((Get-Item -LiteralPath $cache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка загрузок не должна быть ссылкой.'}
 foreach($name in @('mihomo','wintun','warpscout')){
  if($SkipBootstrap -and $name -eq 'warpscout'){continue}
  $item=$manifest.$name;$target=Join-Path $cache $item.file
  if((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target).Hash -ieq $item.sha256){continue}
  # Reuse only an exact-hash, vendor-signed Wintun already present on this computer.
  if($name -eq 'wintun'){
   $found=$false
   foreach($candidate in @((Join-Path $env:ProgramFiles 'WireGuard\wintun.dll'),(Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\wintun.dll'),(Join-Path $env:ProgramFiles 'FlyFrogLLC\Happ\core\wintun.dll'))){
    if((Test-Path -LiteralPath $candidate) -and (Get-FileHash -LiteralPath $candidate).Hash -ieq $item.sha256 -and (Get-AuthenticodeSignature -LiteralPath $candidate).Status -eq 'Valid'){Copy-Item -LiteralPath $candidate -Destination $target -Force;$found=$true;break}
   }
   if($found){continue}
  }
  $archive=Join-Path $cache ($name+'.zip')
  if(-not(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash -ine $item.archiveSha256){
   $partial=$archive+'.download'
   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
   Invoke-WebRequest -UseBasicParsing -Uri $item.url -OutFile $partial -TimeoutSec 60
   if((Get-Item -LiteralPath $partial).Length -gt 80MB -or (Get-FileHash -LiteralPath $partial).Hash -ine $item.archiveSha256){throw ('Не совпала контрольная сумма загрузки: '+$name)}
   Move-Item -LiteralPath $partial -Destination $archive -Force
  }
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  try{
   $entries=@($zip.Entries|Where-Object FullName -ceq $item.entry)
   if($entries.Count -ne 1 -or $entries[0].Length -gt 80MB){throw 'Неожиданный состав архива WARP.'}
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],$target,$true)
   if($name -eq 'wintun'){
    $license=@($zip.Entries|Where-Object {$_.FullName -match '(?i)(^|/)(COPYING|LICENSE)(\.txt)?$'}|Select-Object -First 1)
    if($license.Count -and $license[0].Length -lt 65536){[IO.Compression.ZipFileExtensions]::ExtractToFile($license[0],(Join-Path $cache 'LICENSE-Wintun'),$true)}
   }
  }finally{$zip.Dispose()}
  if((Get-FileHash -LiteralPath $target).Hash -ine $item.sha256){throw ('Не совпала контрольная сумма компонента: '+$name)}
 }
 return $cache
}
