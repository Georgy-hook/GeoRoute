#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([ValidateSet('Boot','Start','Apply','Stop','Inspect','Routes')][string]$Action,[Parameter(Mandatory=$true)][string]$DataRoot)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$program=$PSScriptRoot
$expectedData=Join-Path $env:ProgramData 'GeoRouteWarp'
if([IO.Path]::GetFullPath($DataRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath($expectedData)){throw 'invalid_data_root'}
$private=Join-Path $DataRoot 'private'
$statePath=Join-Path $private 'network-state.json'
$hostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$encoding=[Text.Encoding]::GetEncoding(28591)
$utf8=[Text.UTF8Encoding]::new($false)
$pattern='(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)'
$stamp='# Transport: GeoRouteWARP'
$result=@{ok=$false;errorCode='network_operation_failed'}

function Assert-Path([string]$Path){
 $part=[IO.Path]::GetFullPath($Path)
 while($part){
  if((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'reparse_point'}
  $parent=Split-Path $part -Parent;if($parent -eq $part){break};$part=$parent
 }
}
function Hash-Bytes([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}}
function Save-Json([string]$Path,$Value){
 Assert-Path $Path
 $temp=$Path+'.tmp'
 [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 30),$utf8)
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
}
function Read-State {if(Test-Path -LiteralPath $statePath){Assert-Path $statePath;return (Get-Content -Raw -LiteralPath $statePath -Encoding UTF8|ConvertFrom-Json)};return $null}
function Get-Block([string]$Text){
 $matches=[regex]::Matches($Text,$pattern)
 if($matches.Count -gt 1){throw 'duplicate_managed_blocks'}
 if(-not $matches.Count -and $Text -match '# (BEGIN|END) CHATGPT-US-WINDOWS'){throw 'damaged_managed_block'}
 if($matches.Count){return $matches[0]};return $null
}
function Commit-Hosts([byte[]]$Before,[byte[]]$After){
 Assert-Path $hostsPath
 $temp=Join-Path (Split-Path $hostsPath -Parent) ('.georoute-warp-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  [IO.File]::WriteAllBytes($temp,$After)
  if((Hash-Bytes ([IO.File]::ReadAllBytes($hostsPath))) -cne (Hash-Bytes $Before)){throw 'hosts_changed_concurrently'}
  [IO.File]::Replace($temp,$hostsPath,[NullString]::Value)
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
 Clear-DnsClientCache
}
function Defaults { @((Get-NetRoute|Where-Object {$_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0')}|Sort-Object DestinationPrefix,InterfaceIndex,NextHop|Select-Object DestinationPrefix,NextHop,InterfaceIndex,RouteMetric))|ConvertTo-Json -Compress }
function Own-Adapter($State){
 if(-not $State -or -not $State.adapterGuid){return $null}
 $adapter=Get-NetAdapter -Name 'GeoRouteWARP' -IncludeHidden -ErrorAction SilentlyContinue
 if($adapter -and [string]$adapter.InterfaceGuid -ceq [string]$State.adapterGuid){return $adapter};return $null
}
function Own-Core($State){
 if(-not $State -or -not $State.corePid){return $null}
 $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$State.corePid)
 if($process -and $process.ExecutablePath -ieq (Join-Path $program 'mihomo.exe') -and $process.CommandLine.Contains((Join-Path $private 'core.json')) -and ([datetime]$process.CreationDate).ToUniversalTime().ToString('o') -ceq [string]$State.coreCreated){return $process};return $null
}
function Stop-Network {
 $state=Read-State
 $retainState=$false
 $errors=[Collections.Generic.List[string]]::new()
 # Remove only the exact transport-owned block; manual/external edits survive.
 try{
  for($attempt=0;$attempt -lt 3;$attempt++){
   $before=[IO.File]::ReadAllBytes($hostsPath);$text=$encoding.GetString($before)
   if(-not $text.Contains($stamp)){break}
   $block=Get-Block $text
   if(-not $block -or -not $block.Value.Contains($stamp)){break}
   if(-not $state -or -not $state.blockHash){throw 'hosts_ownership_missing'}
   if((Hash-Bytes ($encoding.GetBytes($block.Value))) -cne [string]$state.blockHash){$retainState=$true;break}
   $after=$text.Remove($block.Index,$block.Length)
   if($state -and $state.baseBytes){
    $base=[Convert]::FromBase64String([string]$state.baseBytes)
    if($after -ceq ($encoding.GetString($base)+"`r`n")){$after=$encoding.GetString($base)}
   }
   try{Commit-Hosts $before ($encoding.GetBytes($after));break}catch{if($_.Exception.Message -ne 'hosts_changed_concurrently' -or $attempt -eq 2){throw}}
  }
 }catch{$errors.Add('hosts_cleanup_failed')}
 $adapter=Own-Adapter $state
 if($adapter){
  foreach($address in @($state.addresses)){
   try{Get-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue|Where-Object {$_.NextHop -eq '0.0.0.0'}|Remove-NetRoute -Confirm:$false -ErrorAction Stop}catch{$errors.Add('route_cleanup_failed')}
  }
 }
 $core=Own-Core $state
 if($core){try{Stop-Process -Id $core.ProcessId -ErrorAction Stop}catch{$errors.Add('core_cleanup_failed')}}
 if($errors.Count){throw ($errors -join '_')}
 if(-not $retainState -and (Test-Path -LiteralPath $statePath)){Remove-Item -LiteralPath $statePath -Force}
 return @{ok=$true}
}
function Read-Settings {
 $path=Join-Path $private 'settings.json';Assert-Path $path
 $value=Get-Content -Raw -LiteralPath $path -Encoding UTF8|ConvertFrom-Json
 if($value.schema -ne 1 -or $value.ownerSid -notmatch '^S-1-5-21-(\d+-){2}\d+-\d+$'){throw 'invalid_settings'}
 if(@($value.profile.map).Count -lt 1 -or @($value.profile.map).Count -gt 512){throw 'invalid_profile'}
 foreach($record in $value.profile.map){
  $ip=$null
  if(-not [Net.IPAddress]::TryParse([string]$record.address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne [string]$record.address){throw 'invalid_target'}
  if([string]$record.domain -cnotmatch '^[a-z0-9.-]+$' -or ([string]$record.domain).Length -gt 253){throw 'invalid_domain'}
 }
 return $value
}
function New-CoreConfig($Template,[string]$InterfaceName){
 $Template|Add-Member NoteProperty 'interface-name' $InterfaceName -Force
 return @{'allow-lan'=$false;'bind-address'='127.0.0.1';mode='rule';'log-level'='warning';ipv6=$false;'interface-name'=$InterfaceName;'find-process-mode'='off';dns=@{enable=$false;'fake-ip-range'='172.31.255.1/30'};profile=@{'store-selected'=$false;'store-fake-ip'=$false};'geo-auto-update'=$false;proxies=@($Template);rules=@('MATCH,WARP-GeoHide');tun=@{enable=$true;device='GeoRouteWARP';stack='gvisor';'auto-route'=$false;'auto-redirect'=$false;'auto-detect-interface'=$false;'dns-mode'='disabled';'dns-hijack'=@();'strict-route'=$false;mtu=1280}}
}
function Start-Network {
 $settings=Read-Settings
 $addresses=@(@($settings.profile.map|ForEach-Object {[string]$_.address})+@($settings.extraRoutes)|Sort-Object -Unique)
 if($addresses.Count -gt 96){throw 'too_many_routes'}
 foreach($address in $addresses){if(Get-NetRoute -DestinationPrefix ($address+'/32') -ErrorAction SilentlyContinue){throw 'existing_route_conflict'}}
 if(Get-NetAdapter -Name 'GeoRouteWARP' -IncludeHidden -ErrorAction SilentlyContinue){throw 'adapter_name_conflict'}
 foreach($item in @(@{Path='mihomo.exe';Hash=$settings.coreSha256},@{Path='wintun.dll';Hash=$settings.wintunSha256})){
  $path=Join-Path $program $item.Path;Assert-Path $path
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$item.Hash){throw 'runtime_hash_mismatch'}
 }
 $physical=@(Get-NetAdapter -Physical|Where-Object {$_.Status -eq 'Up' -and [string]$_.InterfaceGuid -eq [string]$settings.physicalInterfaceGuid}|Select-Object -First 1)
 if(-not $physical.Count){
  $physical=@(Get-NetAdapter -Physical|Where-Object {$_.Status -eq 'Up'}|Where-Object {(Get-NetIPConfiguration -InterfaceIndex $_.ifIndex).IPv4DefaultGateway}|Select-Object -First 1)
 }
 if(-not $physical.Count){throw 'physical_network_unavailable'}
 $template=Get-Content -Raw -LiteralPath (Join-Path $private 'warp-proxy.json') -Encoding UTF8|ConvertFrom-Json
 $coreConfig=New-CoreConfig $template ([string]$physical[0].Name)
 Save-Json (Join-Path $private 'core.json') $coreConfig
 $defaults=Defaults
 $dns=@(Get-DnsClientServerAddress|Sort-Object InterfaceIndex,AddressFamily|Select-Object InterfaceIndex,AddressFamily,ServerAddresses)
 $core=Start-Process -FilePath (Join-Path $program 'mihomo.exe') -ArgumentList @('-d',('"'+$program+'"'),'-f',('"'+(Join-Path $private 'core.json')+'"')) -WorkingDirectory $program -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $DataRoot 'public\core.log') -RedirectStandardError (Join-Path $DataRoot 'public\core-error.log')
 $coreInfo=Get-CimInstance Win32_Process -Filter ('ProcessId='+$core.Id)
 $state=[ordered]@{corePid=$core.Id;coreCreated=([datetime]$coreInfo.CreationDate).ToUniversalTime().ToString('o');adapterGuid='';addresses=$addresses;blockHash='';baseBytes=''}
 Save-Json $statePath $state
 $until=(Get-Date).AddSeconds(15);$adapter=$null
 do{
  if($core.HasExited){throw 'core_exited'}
  $adapter=Get-NetAdapter -Name GeoRouteWARP -IncludeHidden -ErrorAction SilentlyContinue
  if($adapter){break};Start-Sleep -Milliseconds 200
 }while((Get-Date) -lt $until)
 if(-not $adapter){throw 'adapter_start_timeout'}
 $state.adapterGuid=[string]$adapter.InterfaceGuid;Save-Json $statePath $state
 if((Defaults) -cne $defaults){throw 'unexpected_default_route_change'}
 $dnsAfter=@(Get-DnsClientServerAddress|Where-Object {$_.InterfaceIndex -ne $adapter.ifIndex}|Sort-Object InterfaceIndex,AddressFamily|Select-Object InterfaceIndex,AddressFamily,ServerAddresses)
 if(($dns|ConvertTo-Json -Depth 7 -Compress) -cne ($dnsAfter|ConvertTo-Json -Depth 7 -Compress)){throw 'unexpected_dns_change'}
 foreach($address in $addresses){New-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore|Out-Null}
 $local=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4|Where-Object {$_.IPAddress -notlike '169.254.*'}|Select-Object -First 1)
 if(-not $local.Count){throw 'tun_address_unavailable'}
 return @{ok=$true;interfaceIndex=$adapter.ifIndex;localAddress=[string]$local[0].IPAddress;addresses=$addresses}
}
function Apply-Hosts {
 $settings=Read-Settings;$state=Read-State
 if(-not (Own-Adapter $state) -or -not (Own-Core $state)){throw 'transport_not_running'}
 for($attempt=0;$attempt -lt 3;$attempt++){
  $before=[IO.File]::ReadAllBytes($hostsPath)
  if($before.Length -gt 1048576 -or $before -contains [byte]0){throw 'unsupported_hosts_file'}
  $text=$encoding.GetString($before);$block=Get-Block $text
  $base=if($block){$text.Remove($block.Index,$block.Length)}else{$text}
  $domains=@($settings.profile.map|ForEach-Object {[string]$_.domain})
  foreach($line in ($base -split '\r?\n')){
   $parts=@(($line -split '#',2)[0].Trim() -split '\s+')
   if($parts.Count -gt 1){foreach($domain in @($parts|Select-Object -Skip 1)){if($domain -in $domains){throw 'unmanaged_hosts_conflict'}}}
  }
  $lines=@('# BEGIN CHATGPT-US-WINDOWS',$stamp,('# Profile ID: '+$settings.profile.id),('# Owner SID: '+$settings.ownerSid))
  $lines+=@($settings.profile.map|ForEach-Object {[string]$_.address+' '+[string]$_.domain})
  $lines+='# END CHATGPT-US-WINDOWS'
  $owned=($lines -join "`r`n")+"`r`n"
  $state.blockHash=Hash-Bytes ($encoding.GetBytes($owned));$state.baseBytes=[Convert]::ToBase64String($encoding.GetBytes($base));Save-Json $statePath $state
  try{Commit-Hosts $before ($encoding.GetBytes($base+"`r`n"+$owned));break}catch{if($_.Exception.Message -ne 'hosts_changed_concurrently' -or $attempt -eq 2){throw}}
 }
 return @{ok=$true}
}
function Sync-Routes {
 $settings=Read-Settings;$state=Read-State;$adapter=Own-Adapter $state
 if(-not $adapter -or -not (Own-Core $state)){throw 'transport_not_running'}
 $wanted=@(@($settings.profile.map|ForEach-Object {[string]$_.address})+@($settings.extraRoutes)|Sort-Object -Unique)
 if($wanted.Count -gt 96){throw 'too_many_routes'}
 foreach($address in $wanted){
  $ip=$null;if(-not [Net.IPAddress]::TryParse([string]$address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne [string]$address){throw 'invalid_target'}
  $foreign=@(Get-NetRoute -DestinationPrefix ($address+'/32') -ErrorAction SilentlyContinue|Where-Object {$_.InterfaceIndex -ne $adapter.ifIndex})
  if($foreign.Count){throw 'existing_route_conflict'}
 }
 $old=@($state.addresses)
 $state.addresses=@($old+$wanted|Sort-Object -Unique);Save-Json $statePath $state
 foreach($address in $wanted){if(-not(Get-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue)){New-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore|Out-Null}}
 foreach($address in $old){if($address -notin $wanted){Get-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue|Where-Object {$_.NextHop -eq '0.0.0.0'}|Remove-NetRoute -Confirm:$false}}
 $state.addresses=$wanted;Save-Json $statePath $state
 return @{ok=$true;addresses=$wanted}
}
try{
 Assert-Path $program;Assert-Path $DataRoot
 switch($Action){
  Boot {$result=@{ok=$true;boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('yyyyMMddHHmmss.fffffff')}}
  Start {$result=Start-Network}
  Apply {$result=Apply-Hosts}
  Routes {$result=Sync-Routes}
  Stop {$result=Stop-Network}
  Inspect {
   $state=Read-State;$adapter=Own-Adapter $state;$core=Own-Core $state
   $block=Get-Block ($encoding.GetString([IO.File]::ReadAllBytes($hostsPath)))
   $owned=$state -and $state.blockHash -and $block -and (Hash-Bytes ($encoding.GetBytes($block.Value))) -ceq [string]$state.blockHash
   $routes=$true
   if($adapter){foreach($address in @($state.addresses)){if(-not(Get-NetRoute -DestinationPrefix ($address+'/32') -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue)){$routes=$false}}}
   $result=@{ok=$true;healthy=[bool]($adapter -and $core -and $routes -and $owned);externalChange=[bool]($state -and $state.blockHash -and -not $owned)}
  }
 }
}catch{
 $code=[string]$_.Exception.Message
 if($code -cnotmatch '^[a-z_]{1,160}$'){$code='network_operation_failed'}
 $result=@{ok=$false;errorCode=$code}
}
'GEOROUTE_WARP_RESULT='+($result|ConvertTo-Json -Depth 8 -Compress)
if(-not $result.ok){exit 1}
