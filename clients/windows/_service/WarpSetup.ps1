#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
 [ValidateSet('Install','Uninstall')][string]$Mode='Install',
 [Parameter(Mandatory=$true)][ValidatePattern('^S-1-5-21-(\d+-){2}\d+-\d+$')][string]$ExpectedUserSid,
 [string]$RuntimeDirectory,
 [string]$ImportProxyPath,
 [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'
$source=$PSScriptRoot
$program=Join-Path $env:ProgramFiles 'GeoRoute WARP'
$data=Join-Path $env:ProgramData 'GeoRouteWarp'
$private=Join-Path $data 'private'
$public=Join-Path $data 'public'
$python=Join-Path $program 'python\python.exe'
$serviceName='GeoRouteWARP'
$serviceCommand='"'+$python+'" -I -u "'+(Join-Path $program 'warp_manager.py')+'" --program-dir "'+$program+'" --data-dir "'+$data+'" --service'
$created=$false
$setupLock=$null
$resultAllowed=$false
function Assert-WarpPath([string]$Path){
 $value=[IO.Path]::GetFullPath($Path)
 if($value.StartsWith('\\')){throw 'Local paths are required.'}
 while($value){if((Test-Path -LiteralPath $value) -and ((Get-Item -LiteralPath $value -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse points are not allowed.'};$parent=Split-Path $value -Parent;if($parent -eq $value){break};$value=$parent}
}
function Protect-WarpDirectory([string]$Path,[ValidateSet('Program','Private','Public','Requests')][string]$Kind){
 Assert-WarpPath $Path;[IO.Directory]::CreateDirectory($Path)|Out-Null
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
 $rights=@{'S-1-5-18'='FullControl';'S-1-5-32-544'='FullControl'}
 if($Kind -in @('Program','Public')){$rights['S-1-5-32-545']='ReadAndExecute'}
 if($Kind -eq 'Requests'){$rights[$ExpectedUserSid]='Modify'}
 foreach($sid in $rights.Keys){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]$rights[$sid],'ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function Protect-WarpFile([string]$Path,[bool]$Readable){
 Assert-WarpPath $Path
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
 foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
 if($Readable){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','Allow'))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-TrustedWarpData {
 if(-not(Test-Path -LiteralPath $data)){return}
 Assert-WarpPath $data
 $items=@(Get-Item -LiteralPath $data)
 foreach($folder in @($private,$public)){
  if(Test-Path -LiteralPath $folder){Assert-WarpPath $folder;$items+=@(Get-Item -LiteralPath $folder)+@(Get-ChildItem -LiteralPath $folder -Recurse -Force)}
 }
 foreach($item in $items){
  Assert-WarpPath $item.FullName
  $owner=(Get-Acl -LiteralPath $item.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value
  if($owner -notin @('S-1-5-18','S-1-5-32-544')){throw 'Existing WARP data is not administrator-owned; installation was stopped.'}
 }
}
function Get-OwnWarpService {
 $value=Get-CimInstance Win32_Service -Filter "Name='GeoRouteWARP'"
 if($value -and $value.PathName -cne $serviceCommand){throw 'The GeoRouteWARP service name is occupied by another program.'}
 return $value
}
function Wait-WarpExit {
 $service=Get-Service -Name $serviceName -ErrorAction SilentlyContinue
 if($service -and $service.Status -ne 'Stopped'){Stop-Service -Name $serviceName -ErrorAction Stop;$service.WaitForStatus('Stopped',[timespan]::FromSeconds(45))}
}
function Run-WarpTool([string]$Exe,[string[]]$Arguments,[int]$Timeout=90){
 $out=Join-Path $private 'bootstrap-output.log';$err=Join-Path $private 'bootstrap-error.log'
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Exe;$start.Arguments=$Arguments -join ' ';$start.WorkingDirectory=$program
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 try{
  [void]$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  if(-not $process.WaitForExit($Timeout*1000)){$process.Kill();[void]$process.WaitForExit(3000);throw 'WARP bootstrap timed out.'}
  [IO.File]::WriteAllText($out,$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($err,$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  if($process.ExitCode -ne 0){throw 'WARP bootstrap failed. Protected diagnostic logs were retained.'}
 }finally{$process.Dispose()}
}
function Save-WarpJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
try{
 Assert-WarpPath $ResultPath
 $resultRoot=[IO.Path]::GetFullPath((Join-Path $source 'run-results')).TrimEnd('\')+'\'
 if(-not [IO.Path]::GetFullPath($ResultPath).StartsWith($resultRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($ResultPath) -cnotmatch '^warp-[a-f0-9]{32}\.setup\.json$'){throw 'Invalid setup result location.'}
 $resultAllowed=$true
 $setupLock=[Threading.Mutex]::new($false,'Global\GeoRoute.WarpSetup')
 if(-not $setupLock.WaitOne(0)){throw 'Another WARP setup operation is already running.'}
 $actualSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($actualSid -cne $ExpectedUserSid){throw 'Elevation changed the Windows account; install from the intended administrator account.'}
 $old=Get-OwnWarpService
 Assert-TrustedWarpData
 if(Test-Path -LiteralPath (Join-Path $public 'owner.json')){
  $owner=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $public 'owner.json')|ConvertFrom-Json
  if($owner.ownerSid -cne $ExpectedUserSid){throw 'This WARP component belongs to another Windows account.'}
 }
 if($Mode -eq 'Uninstall'){
  if($old){
   Wait-WarpExit
   $lastStatus=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $public 'status.json')|ConvertFrom-Json
   if($lastStatus.state -eq 'cleanup-required'){throw 'Disconnect cleanup requires attention; the installed controller was retained.'}
   & "$env:SystemRoot\System32\sc.exe" delete $serviceName|Out-Null;if($LASTEXITCODE){throw 'Cannot remove the owned WARP service.'}
  }
  if(Test-Path -LiteralPath (Join-Path $private 'settings.json')){$settings=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $private 'settings.json')|ConvertFrom-Json;$settings.autoStart=$false;Save-WarpJson (Join-Path $private 'settings.json') $settings}
  if(Test-Path -LiteralPath (Join-Path $private 'session.json')){Remove-Item -LiteralPath (Join-Path $private 'session.json') -Force}
  if(Test-Path -LiteralPath $public){Save-WarpJson (Join-Path $public 'status.json') @{schema=1;installed=$false;connected=$false;state='not-installed';autoStart=$false}}
  # Preserve protected keys/backups for reinstallation; delete only the exact owned program folder.
  if((Test-Path -LiteralPath $program) -and [IO.Path]::GetFullPath($program) -ieq (Join-Path $env:ProgramFiles 'GeoRoute WARP')){Assert-WarpPath $program;Remove-Item -LiteralPath $program -Recurse -Force}
 }else{
  if(-not $RuntimeDirectory){throw 'Prepare the verified optional runtime first.'}
  Assert-WarpPath $RuntimeDirectory
  $manifest=Get-Content -Raw -LiteralPath (Join-Path $source 'warp-runtime.json') -Encoding UTF8|ConvertFrom-Json
  foreach($name in @('mihomo','wintun','warpscout')){
   if($name -eq 'warpscout' -and $ImportProxyPath){continue}
   $item=$manifest.$name;$path=Join-Path $RuntimeDirectory $item.file;Assert-WarpPath $path
   if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $item.sha256){throw ('Runtime hash mismatch: '+$name)}
  }
  $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $RuntimeDirectory 'wintun.dll')
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC(?:,|$)'){throw 'The Wintun publisher signature is invalid.'}
  $runtimeSource=Join-Path $source 'bridge\python'
  $runtimeHashes=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $source 'bridge\runtime-hashes.json')|ConvertFrom-Json
  foreach($entry in $runtimeHashes.PSObject.Properties){
   $path=[IO.Path]::GetFullPath((Join-Path $runtimeSource $entry.Name))
   if(-not $path.StartsWith(([IO.Path]::GetFullPath($runtimeSource)+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid Python runtime manifest path.'}
   Assert-WarpPath $path
   if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Value){throw 'Bundled Python runtime integrity check failed.'}
  }
  if($old){Wait-WarpExit}
  Protect-WarpDirectory $program Program
  Protect-WarpDirectory $data Public
  Protect-WarpDirectory $private Private
  Protect-WarpDirectory $public Public
  Protect-WarpDirectory (Join-Path $data 'requests') Requests
  foreach($entry in $runtimeHashes.PSObject.Properties){$target=Join-Path (Join-Path $program 'python') $entry.Name;[IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null;Copy-Item -LiteralPath (Join-Path $runtimeSource $entry.Name) -Destination $target -Force}
  foreach($entry in $runtimeHashes.PSObject.Properties){if((Get-FileHash -LiteralPath (Join-Path (Join-Path $program 'python') $entry.Name)).Hash -ine $entry.Value){throw 'Installed Python runtime integrity check failed.'}}
  foreach($file in @('warp_manager.py','warp_windows_service.py','warp_provision.py')){$path=Join-Path $source ('warp\'+$file);Assert-WarpPath $path;Copy-Item -LiteralPath $path -Destination (Join-Path $program $file) -Force}
  foreach($file in @('LICENSE-Mihomo','LICENSE-WARPSCOUT','LICENSE-Wintun')){Copy-Item -LiteralPath (Join-Path $source ('warp\licenses\'+$file)) -Destination (Join-Path $program $file) -Force}
  foreach($file in @('WarpNetwork.ps1','gemini_probe.py')){$path=Join-Path $source $file;Assert-WarpPath $path;Copy-Item -LiteralPath $path -Destination (Join-Path $program $file) -Force}
  [IO.Directory]::CreateDirectory((Join-Path $program 'vendor'))|Out-Null
  Copy-Item -LiteralPath (Join-Path $source 'vendor\hashes.json') -Destination (Join-Path $program 'vendor\hashes.json') -Force
  $vendor=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $source 'vendor\hashes.json')|ConvertFrom-Json
  foreach($entry in $vendor.PSObject.Properties){
   if($entry.Name -cnotmatch '^[a-z0-9_.-]+\.whl$'){throw 'Invalid HTTP/2 dependency path.'}
   $path=Join-Path $source ('vendor\'+$entry.Name)
   if((Get-FileHash -LiteralPath $path).Hash -ine $entry.Value){throw 'HTTP/2 dependency hash mismatch.'}
   Copy-Item -LiteralPath $path -Destination (Join-Path $program ('vendor\'+$entry.Name)) -Force
  }
  foreach($file in @('mihomo.exe','wintun.dll')){Copy-Item -LiteralPath (Join-Path $RuntimeDirectory $file) -Destination (Join-Path $program $file) -Force}
  foreach($name in @('mihomo','wintun')){$item=$manifest.$name;if((Get-FileHash -LiteralPath (Join-Path $program $item.file)).Hash -ine $item.sha256){throw 'Installed WARP runtime integrity check failed.'}}
  if(Test-Path -LiteralPath (Join-Path $RuntimeDirectory 'LICENSE-Wintun')){$license=Join-Path $RuntimeDirectory 'LICENSE-Wintun';Assert-WarpPath $license;if((Get-Item -LiteralPath $license).Length -gt 65536){throw 'Unexpected license size.'};Copy-Item -LiteralPath $license -Destination $program -Force}
  $proxyPath=Join-Path $private 'warp-proxy.json'
  if($ImportProxyPath){
   Assert-WarpPath $ImportProxyPath
   Run-WarpTool $python @('-I',('"'+(Join-Path $program 'warp_provision.py')+'"'),'--input',('"'+$ImportProxyPath+'"'),'--output',('"'+$proxyPath+'"'))
  }elseif(-not $old -or -not(Test-Path -LiteralPath $proxyPath)){
   $bootstrap=Join-Path $private 'warpscout.exe';Copy-Item -LiteralPath (Join-Path $RuntimeDirectory 'warpscout.exe') -Destination $bootstrap
   try{
    $account=Join-Path $private 'warp-account.json';$export=Join-Path $private 'warp-export.json'
    if(-not $old -and (Test-Path -LiteralPath $account)){Remove-Item -LiteralPath $account -Force}
    if(-not(Test-Path -LiteralPath $account)){Run-WarpTool $bootstrap @('register','-relay','none','-target','162.159.192.1,188.114.98.58,188.114.99.218,162.159.195.1','-t','3','-a',('"'+$account+'"')) 90}
    Run-WarpTool $bootstrap @('scan','-p','awg','-target','162.159.192.1,188.114.98.58,188.114.99.218,162.159.195.1','-port','4500','-P','-tun-ping-count','5','-jt','1','-t','3','-a',('"'+$account+'"'),'-plain','-no-report','-no-dns','-conf',('"'+$export+'"'),'-conf-type','mihomo-json') 90
    Run-WarpTool $python @('-I',('"'+(Join-Path $program 'warp_provision.py')+'"'),'--input',('"'+$export+'"'),'--output',('"'+$proxyPath+'"'))
   }finally{if(Test-Path -LiteralPath $bootstrap){Remove-Item -LiteralPath $bootstrap -Force}}
  }
  # Revalidate even a retained template before it can be loaded by SYSTEM.
  $cleanProxy=Join-Path $private 'warp-proxy.sanitized.json'
  Run-WarpTool $python @('-I',('"'+(Join-Path $program 'warp_provision.py')+'"'),'--input',('"'+$proxyPath+'"'),'--output',('"'+$cleanProxy+'"'))
  Move-Item -LiteralPath $cleanProxy -Destination $proxyPath -Force
  $settingsPath=Join-Path $private 'settings.json'
  if($old -and (Test-Path -LiteralPath $settingsPath)){$settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath|ConvertFrom-Json}
  else{
   $physical=Get-NetAdapter -Physical|Where-Object {$_.Status -eq 'Up'}|Where-Object {(Get-NetIPConfiguration -InterfaceIndex $_.ifIndex).IPv4DefaultGateway}|Select-Object -First 1
   if(-not $physical){throw 'No physical IPv4 network is available.'}
   $domains=@('gemini.google.com','www.google.com','geminiweb-pa.clients6.google.com','geminiweb-pa.clients.google.com','generativelanguage.googleapis.com','geller-pa.googleapis.com','proactivebackend-pa.googleapis.com','robinfrontend-pa.googleapis.com')
   $settings=[pscustomobject]@{schema=1;ownerSid=$ExpectedUserSid;autoStart=$false;physicalInterfaceGuid=[string]$physical.InterfaceGuid;profile=@{id='warp-default';name='GeoHide EU · WARP';map=@($domains|ForEach-Object {@{domain=$_;address='37.221.93.141'}})}}
  }
  $settings|Add-Member NoteProperty coreSha256 ([string]$manifest.mihomo.sha256) -Force
  $settings|Add-Member NoteProperty wintunSha256 ([string]$manifest.wintun.sha256) -Force
  if(-not $settings.PSObject.Properties['extraRoutes']){
   $catalog=Get-Content -Raw -LiteralPath (Join-Path $source 'geohide-servers.json') -Encoding UTF8|ConvertFrom-Json
   $settings|Add-Member NoteProperty extraRoutes @($catalog.servers|Where-Object {$_.region -in @('US','EU')}|ForEach-Object address|Sort-Object -Unique)
  }
  Save-WarpJson $settingsPath $settings
  # Keep file ownership administrator-bound as well as directory inheritance.
  foreach($pair in @(@{Root=$program;Kind='Program'},@{Root=$private;Kind='Private'},@{Root=$public;Kind='Public'})){
   foreach($item in @(Get-Item -LiteralPath $pair.Root)+@(Get-ChildItem -LiteralPath $pair.Root -Recurse -Force)){
    if($item.PSIsContainer){Protect-WarpDirectory $item.FullName $pair.Kind}else{Protect-WarpFile $item.FullName ($pair.Kind -ne 'Private')}
   }
  }
  Save-WarpJson (Join-Path $public 'owner.json') @{ownerSid=$ExpectedUserSid;schema=1;coreVersion=$manifest.mihomo.version;controllerVersion='1'}
  if(-not $old){New-Service -Name $serviceName -DisplayName 'GeoRoute WARP Controller' -BinaryPathName $serviceCommand -StartupType Automatic -Description 'On-demand WARP for exact GeoHide IPs. Connection automatic start is an independent, owner-controlled preference.'|Out-Null;$created=$true}
  Set-Service -Name $serviceName -StartupType Automatic
  # The owner can issue only fixed, schema-validated AI routing controls, not change service code/configuration.
  $sddl='D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPLOCRRC;;;'+$ExpectedUserSid+')'
  & "$env:SystemRoot\System32\sc.exe" sdset $serviceName $sddl|Out-Null;if($LASTEXITCODE){throw 'Cannot set the account-bound service controls.'}
  & "$env:SystemRoot\System32\sc.exe" failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000|Out-Null;if($LASTEXITCODE){throw 'Cannot configure service recovery.'}
  Start-Service -Name $serviceName
 }
 [ordered]@{Status='ok';Mode=$Mode;Message=$(if($Mode -eq 'Install'){'WARP installed; automatic connection remains a separate setting.'}else{'WARP removed; protected account/backups retained.'});At=[DateTimeOffset]::Now.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $ResultPath -Encoding UTF8
}catch{
 if($created){try{Stop-Service -Name $serviceName -ErrorAction SilentlyContinue;& "$env:SystemRoot\System32\sc.exe" delete $serviceName|Out-Null}catch{}}
 if($resultAllowed){[ordered]@{Status='error';Mode=$Mode;Error=$_.Exception.Message;At=[DateTimeOffset]::Now.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $ResultPath -Encoding UTF8}else{Write-Error 'Invalid setup result location.'}
 exit 1
}finally{if($setupLock){try{$setupLock.ReleaseMutex()}catch{};$setupLock.Dispose()}}
