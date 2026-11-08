#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RuntimeRoot)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows'){throw 'Run this SCM/NRPT test only in a disposable GitHub Windows runner.'}
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'SelectiveDns.ps1')
$root=Join-Path $env:RUNNER_TEMP ('GeoRouteDnsCI-'+[guid]::NewGuid().ToString('N'))
$name='GeoRouteDnsCI'+[guid]::NewGuid().ToString('N').Substring(0,12)
$namespace='georoute-'+[guid]::NewGuid().ToString('N')+'.invalid'
$ruleName=$null;$created=$false
$before=Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts';$beforeHosts=(Get-FileHash $hosts).Hash
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.2'),0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
try{
 [IO.Directory]::CreateDirectory($root)|Out-Null
 $data=Join-Path $root 'data';[IO.Directory]::CreateDirectory($data)|Out-Null
 foreach($file in @('bridge.py','selective_dns.py')){Copy-Item (Join-Path $source ('bridge\'+$file)) $root}
 Copy-Item (Join-Path $RuntimeRoot 'python') $root -Recurse
 $config=Join-Path $root 'config.json'
 @{url='https://dns.google/dns-query';servers=@('8.8.8.8');domains=@($namespace);subdomains=$true}|ConvertTo-Json|Set-Content $config -Encoding UTF8
 & icacls.exe $root /grant '*S-1-5-19:(OI)(CI)RX'|Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot grant worker read access'}
 & icacls.exe $data /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
 if($LASTEXITCODE -ne 0){throw 'Cannot grant status access'}
 $command='"'+(Join-Path $root 'python\python.exe')+'" -I -u "'+(Join-Path $root 'selective_dns.py')+'" --mode serve --service --service-name '+$name+' --port '+$port+' --config "'+$config+'" --data-dir "'+$data+'"'
 New-Service -Name $name -BinaryPathName $command -StartupType Manual -Credential ([Management.Automation.PSCredential]::new('NT AUTHORITY\LocalService',[Security.SecureString]::new()))|Out-Null
 $created=$true
 for($attempt=0;$attempt -lt 2;$attempt++){
  Start-Service $name
  $service=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'")
  if($service.State -ne 'Running' -or $service.StartName -ine 'NT AUTHORITY\LocalService'){throw 'Selected DNS did not start under LocalService'}
  # A non-selected query must be refused locally, with no upstream lookup.
  $packet=[byte[]]@(0x43,0x52,1,0,0,1,0,0,0,0,0,0,7,101,120,97,109,112,108,101,3,99,111,109,0,0,1,0,1)
  $udp=[Net.Sockets.UdpClient]::new();$udp.Client.ReceiveTimeout=3000
  try{$udp.Connect('127.0.0.2',$port);[void]$udp.Send($packet,$packet.Length);$remote=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$answer=$udp.Receive([ref]$remote);if(($answer[3] -band 15) -ne 5){throw 'Unselected namespace reached the provider'}}finally{$udp.Dispose()}
  $process=Get-Process -Id $service.ProcessId
  Stop-Service $name
  if(-not $process.WaitForExit(6000)){throw 'Selected DNS stayed alive after stop'}
 }
 $r=Add-DnsClientNrptRule -Namespace @($namespace,('.'+$namespace)) -NameServers '127.0.0.2' -Comment 'GeoRoute selective DNS v1' -DisplayName 'GeoRoute CI' -PassThru
 $ruleName=$r.Name
 if(@(Get-SelectiveDnsOwnRules|Where-Object Name -eq $ruleName).Count -ne 1){throw 'NRPT ownership detection failed'}
 Remove-DnsClientNrptRule -Name $ruleName -Force;$ruleName=$null
 if((Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress) -cne $before -or (Get-FileHash $hosts).Hash -cne $beforeHosts){throw 'Selected DNS changed baseline adapter DNS or hosts'}
 Write-Output 'Selected DNS SCM/NRPT passed: LocalService, isolated loopback, local refusal, restart, namespace roundtrip and unchanged baseline DNS/hosts.'
}finally{
 if($ruleName){Remove-DnsClientNrptRule -Name $ruleName -Force -ErrorAction SilentlyContinue}
 if($created){Stop-Service $name -ErrorAction SilentlyContinue;& sc.exe delete $name|Out-Null}
 $absolute=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
 if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^GeoRouteDnsCI-[a-f0-9]{32}$'){throw 'Unexpected test directory'}
 if(Test-Path $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction SilentlyContinue}
}
