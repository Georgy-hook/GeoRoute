#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeRoot)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows'){throw 'This SCM integration test runs only in the disposable GitHub Windows runner.'}
$runnerRoot=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
$testRoot=[IO.Path]::GetFullPath((Join-Path $runnerRoot ('GeoRouteBridgeTest-'+[guid]::NewGuid().ToString('N'))))
$name='GeoRouteBridgeCI'+[guid]::NewGuid().ToString('N').Substring(0,12)
$worker=Join-Path $testRoot 'bridge.py'
$python=Join-Path $testRoot 'python\python.exe'
$data=Join-Path $testRoot 'data'
$profile=Join-Path $testRoot 'profile.txt'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$command='"'+$python+'" -I -u "'+$worker+'" --service --service-name '+$name+' --profile-file "'+$profile+'" --data-dir "'+$data+'" --port '+$port
$created=$false
function Service-Info {Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'")}
function Wait-ServiceState([string]$State) {
 $watch=[Diagnostics.Stopwatch]::StartNew()
 do {$service=Service-Info;if($service.State -eq $State){return $service};Start-Sleep -Milliseconds 100}while($watch.Elapsed.TotalSeconds -lt 20)
 throw ('Service did not reach '+$State)
}
try {
 New-Item -ItemType Directory -Path $testRoot,$data | Out-Null
 Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) '_service\bridge\bridge.py') -Destination $worker
 Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'python') -Destination $testRoot -Recurse
 [IO.File]::WriteAllText($profile,'abcdef')
 & icacls.exe $testRoot /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot grant service read access'}
 & icacls.exe $data /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot grant service status access'}
 New-Service -Name $name -BinaryPathName $command -StartupType Manual -Credential ([Management.Automation.PSCredential]::new('NT AUTHORITY\LocalService',[Security.SecureString]::new())) | Out-Null
 $created=$true
 for($attempt=0;$attempt -lt 2;$attempt++){
  Start-Service -Name $name
  $service=Wait-ServiceState 'Running'
  if($service.StartName -ine 'NT AUTHORITY\LocalService'){throw 'Service account changed'}
  if(@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$service.ProcessId)).Count){throw 'Direct service spawned a child process'}
  $process=Get-Process -Id $service.ProcessId
  $tcp=[Net.Sockets.TcpClient]::new()
  $tcp.Connect('127.0.0.1',$port)
  Stop-Service -Name $name
  $null=Wait-ServiceState 'Stopped'
  if(-not $process.WaitForExit(6000)){throw 'Service process remained alive after stop'}
  $tcp.Dispose()
  $status=Get-Content -LiteralPath (Join-Path $data 'status.json') -Raw | ConvertFrom-Json
  if($status.running){throw 'Worker status remained running'}
 }
 # A bind failure must be reported to SCM, releasing any previously bound UDP socket.
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
 $listener.Start()
 try {Start-Service -Name $name -ErrorAction Stop}catch{}
 $failed=Wait-ServiceState 'Stopped'
 if($failed.ExitCode -eq 0){throw 'Startup bind failure was reported as success'}
 $listener.Stop()
 $probe=[Net.Sockets.UdpClient]::new()
 try {$probe.Client.ExclusiveAddressUse=$true;$probe.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,$port))}finally{$probe.Dispose()}
 $failedLog=Get-Content -LiteralPath (Join-Path $data 'service.log') -Raw
 if($failedLog -notmatch 'DNS worker failed:'){throw 'Failure diagnostics were not written'}
 Start-Service -Name $name
 $service=Wait-ServiceState 'Running'
 $process=Get-Process -Id $service.ProcessId
 Stop-Service -Name $name
 $null=Wait-ServiceState 'Stopped'
 if(-not $process.WaitForExit(6000)){throw 'Recovery process did not stop'}
 Write-Output '4 SCM integration scenarios passed: LocalService startup, restart, startup failure cleanup, and recovery. No DNS settings changed.'
} catch {
 if(Test-Path -LiteralPath (Join-Path $data 'service.log')){Get-Content -LiteralPath (Join-Path $data 'service.log') -Tail 12 | Write-Output}
 throw
} finally {
 $listener.Stop()
 if($created){
  $service=Service-Info
  if($service.PathName -cne $command){throw 'Refusing to clean up another service'}
  Stop-Service -Name $name -ErrorAction SilentlyContinue
  & sc.exe delete $name | Out-Null
 }
 $resolved=[IO.Path]::GetFullPath($testRoot)
 if(-not $resolved.StartsWith($runnerRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^GeoRouteBridgeTest-[a-f0-9]{32}$'){throw 'Refusing to remove an unexpected test directory'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
