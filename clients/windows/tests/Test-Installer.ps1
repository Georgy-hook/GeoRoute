#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SetupPath,[Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or -not $env:RUNNER_TEMP){throw 'Installer integration is restricted to disposable GitHub Windows runners.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP ('GeoRoute-Installer-'+[guid]::NewGuid().ToString('N'))))
$app=Join-Path $root 'Приложение с пробелами'
$stage=Join-Path $root 'payload'
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName='NextDNS Connection Manager'
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBefore=(Get-FileHash -LiteralPath $hosts).Hash
$dnsBefore=Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress
$proxyBefore=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object AutoConfigURL,ProxyEnable,ProxyServer|ConvertTo-Json -Compress
function Run-Setup([string]$Log) {
 $p=Start-Process -FilePath $SetupPath -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="!desktopicon" /DIR="'+$app+'" /LOG="'+(Join-Path $root $Log)+'"') -Wait -PassThru
 return $p.ExitCode
}
try {
 New-Item -ItemType Directory -Path $root|Out-Null
 [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath,$stage)
 if((Run-Setup 'install.log') -ne 0){throw 'Fresh installation failed'}
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $stage 'GeoRoute') -Recurse -File){
  $relative=$file.FullName.Substring((Join-Path $stage 'GeoRoute').Length+1)
  if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $app $relative)).Hash){throw ('Installed payload differs: '+$relative)}
 }
 $shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) 'GeoRoute.lnk'
 if(-not(Test-Path -LiteralPath $shortcutPath)){throw 'Start menu shortcut missing'}
 $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
 # WScript.Shell exposes ANSI arguments on an English Windows code page.
 # The Shell property store reads the actual Unicode link used by Explorer.
 $linkFolder=(New-Object -ComObject Shell.Application).NameSpace((Split-Path $shortcutPath -Parent))
 $linkArguments=$linkFolder.ParseName('GeoRoute.lnk').ExtendedProperty('System.Link.Arguments')
 if($shortcut.TargetPath -ine $shell -or $linkArguments -notlike ('*"'+$app+'\_service\NextDNS-GUI.ps1"')){throw ('Shortcut mismatch. Target='+$shortcut.TargetPath+'; Unicode arguments='+$linkArguments+'; expected shell='+$shell+'; expected app='+$app)}
 $smoke=Start-Process -FilePath $shortcut.TargetPath -ArgumentList ($linkArguments+' -SmokeTest') -WindowStyle Hidden -Wait -PassThru
 if($smoke.ExitCode -ne 0){throw 'Installed shortcut GUI smoke failed'}
 $mutex=[Threading.Mutex]::new($false,'Local\GeoRoute.Setup.Application')
 try {if((Run-Setup 'running.log') -eq 0){throw 'Installer replaced a running app'}}finally{$mutex.Dispose()}
 $catalog=Join-Path $app '_service\profiles.json'
 $routes=Join-Path $app '_service\connection-routes.json'
 Add-Content -LiteralPath $catalog -Value ' '
 Add-Content -LiteralPath $routes -Value ' '
 $profile=Join-Path $app '_service\profiles\primary.hosts'
 Add-Content -LiteralPath $profile -Value '# installer preservation test'
 $custom=Join-Path $app '_service\profiles\user-test.hosts'
 [IO.File]::WriteAllText($custom,'# user profile')
 $prefs=Join-Path $app '_service\GUI-settings.json'
 [IO.File]::WriteAllText($prefs,'{"reducedMotion":true}')
 $keep=@($catalog,$routes,$profile,$custom,$prefs)
 $hashes=@{};foreach($file in $keep){$hashes[$file]=(Get-FileHash -LiteralPath $file).Hash}
 if((Run-Setup 'upgrade.log') -ne 0){throw 'Upgrade failed'}
 foreach($file in $keep){if((Get-FileHash -LiteralPath $file).Hash -ne $hashes[$file]){throw ('Upgrade lost data: '+$file)}}
 $uninstaller=Join-Path $app 'unins000.exe'
 $evidence=Join-Path (Split-Path $SetupPath -Parent) '..\installer-test-evidence'
 New-Item -ItemType Directory -Path $evidence -Force|Out-Null
 Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $evidence 'unins000.exe')
 # An unrelated portable install's startup value must survive removal.
 New-Item -Path $runKey -Force|Out-Null
 New-ItemProperty -Path $runKey -Name $runName -Value 'unrelated-startup-test' -Force|Out-Null
 $p=Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
 if($p.ExitCode -ne 0 -or (Test-Path -LiteralPath (Join-Path $app 'GeoRoute.cmd'))){throw 'Uninstall failed'}
 if((Get-ItemPropertyValue -LiteralPath $runKey -Name $runName) -ne 'unrelated-startup-test'){throw 'Uninstall removed unrelated startup'}
 foreach($file in $keep){if((Get-FileHash -LiteralPath $file).Hash -ne $hashes[$file]){throw ('Uninstall lost user data: '+$file)}}
 Remove-ItemProperty -LiteralPath $runKey -Name $runName
 if((Run-Setup 'reinstall.log') -ne 0){throw 'Reinstall failed'}
 $own='"'+$env:ComSpec+'" /d /s /c ""'+(Join-Path $app 'GeoRoute.cmd')+'" -Tray"'
 New-ItemProperty -Path $runKey -Name $runName -Value $own -Force|Out-Null
 $p=Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
 if($p.ExitCode -ne 0){throw 'Second uninstall failed'}
 if(Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue){throw 'Dangling owned startup value'}
 if((Get-FileHash -LiteralPath $hosts).Hash -ne $hostsBefore){throw 'Installer changed hosts'}
 if((Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress) -cne $dnsBefore){throw 'Installer changed DNS'}
 $proxyAfter=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object AutoConfigURL,ProxyEnable,ProxyServer|ConvertTo-Json -Compress
 if($proxyAfter -cne $proxyBefore){throw 'Installer changed proxy'}
 Write-Output 'Installer passed: exact payload, Cyrillic path, shortcut GUI, running-app guard, update/reinstall preservation, uninstall, owned startup and untouched network.'
} finally {
 if(-not $root.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP)+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -notmatch '^GeoRoute-Installer-[a-f0-9]{32}$'){throw 'Unexpected integration-test path'}
 if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
