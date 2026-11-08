#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Probe','Enable','Disable','Catalogue')][string]$Mode='Probe',
 [Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProfileCreation.ps1')
. (Join-Path $PSScriptRoot 'SelectiveDns.ps1')
$program=Join-Path $env:ProgramFiles 'GeoRoute DNS'
$data=Join-Path $env:ProgramData 'GeoRouteDNS'
$serviceName='GeoRouteDNS'
$command='"'+(Join-Path $program 'python\python.exe')+'" -I -u "'+(Join-Path $program 'selective_dns.py')+'" --mode serve --service --config "'+(Join-Path $program 'config.json')+'" --data-dir "'+$data+'"'
$resultPath=$null;$lock=$null;$changed=$false;$oldRules=@();$previous=$null;$oldRunning=$false;$oldMode='Disabled'
function Assert-DnsPath([string]$Path) {
 $p=[IO.Path]::GetFullPath($Path)
 while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Путь содержит ссылку.'};$parent=Split-Path $p -Parent;if($parent -eq $p){break};$p=$parent}
}
function Protect-DnsDirectory([string]$Path,[bool]$Writable) {
 Assert-DnsPath $Path;[IO.Directory]::CreateDirectory($Path)|Out-Null
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 $rights=@{'S-1-5-18'='FullControl';'S-1-5-32-544'='FullControl';'S-1-5-32-545'='ReadAndExecute';'S-1-5-19'=$(if($Writable){'Modify'}else{'ReadAndExecute'})}
 foreach($sid in $rights.Keys){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]$rights[$sid],([Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-DnsService {
 $s=Get-CimInstance Win32_Service -Filter "Name='GeoRouteDNS'"
 if($s -and $s.PathName -cne $command){throw 'Имя службы GeoRouteDNS занято другим приложением.'}
 return $s
}
function Stop-DnsService {
 $s=Get-DnsService
 if($s -and $s.State -ne 'Stopped'){
  $p=if($s.ProcessId){Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue}else{$null}
  Stop-Service $serviceName -ErrorAction Stop
  if($p -and -not $p.WaitForExit(10000)){throw 'DNS-служба ещё завершает работу. Повторите позднее.'}
 }
}
function Remove-DnsRules {foreach($r in @(Get-SelectiveDnsOwnRules)){Remove-DnsClientNrptRule -Name $r.Name -Force -ErrorAction Stop}}
function Add-DnsRules($Rules) {
 foreach($rule in $Rules){Add-DnsClientNrptRule -Namespace @($rule.Namespace) -NameServers '127.0.0.2' -Comment 'GeoRoute selective DNS v1' -DisplayName 'GeoRoute — выбранные сайты' -ErrorAction Stop|Out-Null}
}
function Invoke-DnsTool([string]$ToolMode,[string]$ConfigPath,[string]$OutputPath) {
 $python=Join-Path $PSScriptRoot 'bridge\python\python.exe'
 if(-not(Test-Path -LiteralPath $python)){throw 'В комплекте нет Python. Используйте полный пакет GeoRoute.'}
 & $python -I (Join-Path $PSScriptRoot 'bridge\selective_dns.py') --mode $ToolMode --config $ConfigPath --output $OutputPath
 if(-not(Test-Path -LiteralPath $OutputPath)){throw 'DNS-проверка не вернула результат.'}
 $report=Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8|ConvertFrom-Json
 $script:dnsProbeReport=$report
 if($report.status -ne 'ok'){throw ([string]$report.error)}
 return $report
}
try {
 $runRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'run-results'))
 $RequestPath=[IO.Path]::GetFullPath($RequestPath)
 if([IO.Path]::GetDirectoryName($RequestPath) -ine $runRoot -or [IO.Path]::GetFileName($RequestPath) -notmatch '^dns-[a-f0-9]{32}\.request\.json$'){throw 'Некорректный путь DNS-запроса.'}
 Assert-DnsPath $RequestPath
 if((Get-Item -LiteralPath $RequestPath).Length -gt 1MB){throw 'Слишком большой запрос.'}
 $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
 $resultPath=$RequestPath.Replace('.request.json','.result.json')
 $probePath=$RequestPath.Replace('.request.json','.probe.json')
 $configPath=$RequestPath.Replace('.request.json','.config.json')
 foreach($path in @($resultPath,$probePath,$configPath)){Assert-DnsPath $path}
 if($Mode -eq 'Catalogue'){
  $report=Invoke-DnsTool 'catalogue' $configPath $probePath
  $report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $resultPath -Encoding UTF8;exit 0
 }
 if($Mode -ne 'Disable'){
  $cfg=New-SelectiveDnsConfig ([string]$request.Config.url) @($request.Config.servers) @($request.Config.domains) ([bool]$request.Config.subdomains)
  $cfg|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $configPath -Encoding UTF8
  $report=Invoke-DnsTool 'probe' $configPath $probePath
  $cfg=$report.settings
  if($Mode -eq 'Probe'){$report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $resultPath -Encoding UTF8;exit 0}
 }
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 if($identity.User.Value -cne [string]$request.ExpectedUserSid -or -not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Подтвердите Windows от того же пользователя.'}
 Assert-DnsPath $program;Assert-DnsPath $data
 Protect-DnsDirectory $data $true
 $lock=[IO.File]::Open((Join-Path $data 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $service=Get-DnsService
 if($Mode -eq 'Disable'){
  # Remove namespace rules first: a stopped optional service must not strand DNS.
  Remove-DnsRules
  Stop-DnsService
  if($service){Set-Service $serviceName -StartupType Disabled}
  Clear-DnsClientCache
  $message='DNS для выбранных сайтов выключен. Обычный DNS и hosts сохранены.'
 }else{
  $foreign=@(Get-DnsClientNrptRule -ErrorAction Stop)
  Assert-SelectiveDnsConflicts $cfg $foreign ([IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')))
  # Group-policy namespaces may not appear in the local editable-rule collection.
  foreach($policy in @(Get-DnsClientNrptPolicy -Effective -ErrorAction Stop)){
   if((@($policy.NameServers) -join ',') -ne '127.0.0.2'){
    foreach($ns in @($policy.Namespace)){foreach($candidate in @(Get-SelectiveDnsNamespaces $cfg)){if(Test-DnsNamespaceOverlap $ns $candidate){throw 'Сайты пересекаются с действующей DNS-политикой Windows. Она сохранена.'}}}
   }
  }
  $source=Join-Path $PSScriptRoot 'bridge'
  $runtime=Join-Path $source 'python'
  $hashes=Get-Content (Join-Path $source 'runtime-hashes.json') -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($item in $hashes.PSObject.Properties){$path=[IO.Path]::GetFullPath((Join-Path $runtime $item.Name));if(-not $path.StartsWith(($runtime+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Неверный путь runtime.'};Assert-DnsPath $path;if((Get-FileHash $path -Algorithm SHA256).Hash -ine $item.Value){throw 'Python runtime повреждён.'}}
  $oldRules=@(Get-SelectiveDnsOwnRules)
  $oldRunning=$service -and $service.State -eq 'Running'
  if($service){$oldMode=$service.StartMode}
  $previous=Join-Path $data ('rollback-'+[guid]::NewGuid().ToString('N'))
  Protect-DnsDirectory $previous $false
  if(Test-Path -LiteralPath $program){
   foreach($item in @(Get-ChildItem -LiteralPath $program -Recurse -Force)){Assert-DnsPath $item.FullName}
   Copy-Item -LiteralPath $program -Destination (Join-Path $previous 'program') -Recurse
  }
  $oldRules|Select-Object Name,Namespace,NameServers,Comment|ConvertTo-Json -Depth 5|Set-Content (Join-Path $previous 'rules.json') -Encoding UTF8
  $changed=$true
  Stop-DnsService
  Protect-DnsDirectory $program $false
  foreach($name in @('bridge.py','selective_dns.py')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $program $name) -Force}
  [IO.Directory]::CreateDirectory((Join-Path $program 'python'))|Out-Null
  foreach($item in $hashes.PSObject.Properties){$target=Join-Path (Join-Path $program 'python') $item.Name;[IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null;Copy-Item -LiteralPath (Join-Path $runtime $item.Name) -Destination $target -Force}
  $cfg|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $program 'config.json') -Encoding UTF8
  if(-not $service){New-Service -Name $serviceName -DisplayName 'GeoRoute DNS — выбранные сайты' -BinaryPathName $command -StartupType Automatic -Credential ([Management.Automation.PSCredential]::new('NT AUTHORITY\LocalService',[Security.SecureString]::new()))|Out-Null}
  Set-Service $serviceName -StartupType Automatic
  & sc.exe failure $serviceName reset= 86400 actions= restart/3000/restart/10000/restart/30000|Out-Null
  if($LASTEXITCODE -ne 0){throw 'Не удалось настроить восстановление службы.'}
  & sc.exe failureflag $serviceName 1|Out-Null
  if($LASTEXITCODE -ne 0){throw 'Не удалось настроить восстановление службы.'}
  Start-Service $serviceName
  # Prove the protected installed worker answers before installing any namespace rule.
  $reply=Resolve-DnsName -Name $cfg.domains[0] -Server 127.0.0.2 -Type A -DnsOnly -NoHostsFile -ErrorAction Stop
  if(-not @($reply).Count){throw 'Установленный DNS не вернул адрес выбранного сайта.'}
  Remove-DnsRules
  foreach($site in $cfg.domains){$names=@($site);if($cfg.subdomains){$names+=('.'+$site)};Add-DnsRules @([pscustomobject]@{Namespace=$names})}
  $expected=@(Get-SelectiveDnsNamespaces $cfg)|Sort-Object
  $actual=@(Get-SelectiveDnsOwnRules|ForEach-Object {$_.Namespace})|Sort-Object
  if(($expected -join '|') -cne ($actual -join '|')){throw 'DNS-правила сохранены не полностью.'}
  Clear-DnsClientCache
  # Check Windows' own resolver, which must apply the effective namespace policy.
  Assert-SelectiveDnsConflicts $cfg @(Get-DnsClientNrptRule -ErrorAction Stop) ([IO.File]::ReadAllText((Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')))
  $answer=Resolve-DnsName -Name $cfg.domains[0] -Type A -DnsOnly -NoHostsFile -ErrorAction Stop
  if(-not @($answer).Count){throw 'DNS Windows не подтвердил выбранный сайт.'}
  $message='DNS включён для '+$cfg.domains.Count+' сайтов. Другие запросы используют прежний DNS. Служба запускается с Windows.'
 }
 [pscustomobject]@{status='ok';message=$message;settings=$(if($Mode -eq 'Enable'){$cfg}else{$null})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $resultPath -Encoding UTF8
}catch{
 $message=$_.Exception.Message
 if($changed){
  try {
   Remove-DnsRules;Stop-DnsService
   if($previous -and (Test-Path -LiteralPath (Join-Path $previous 'program'))){Copy-Item -Path (Join-Path $previous 'program\*') -Destination $program -Recurse -Force}
   Add-DnsRules $oldRules
   if(Get-DnsService){Set-Service $serviceName -StartupType $(switch($oldMode){'Auto'{'Automatic'}'Manual'{'Manual'}default{'Disabled'}});if($oldRunning){Start-Service $serviceName}}
   Clear-DnsClientCache;$message+=' Предыдущие правила восстановлены.'
  }catch{$message+=' Откат не завершён. Нажмите «Выключить DNS для сайтов»; остальные DNS не менялись.'}
 }
 if($resultPath){[pscustomobject]@{status='error';error=$message;rows=$(if($script:dnsProbeReport -and $script:dnsProbeReport.PSObject.Properties['rows']){@($script:dnsProbeReport.rows)}else{@()})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $resultPath -Encoding UTF8}
 exit 1
}finally{if($lock){$lock.Dispose()}}
