#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SetupPath,[Parameter(Mandatory=$true)][string]$ArchivePath,[string]$ScreenshotDirectory,[switch]$CheckDefaultLocation)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or -not $env:RUNNER_TEMP){throw 'Installer integration is restricted to disposable GitHub Windows runners.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP ('GeoRoute-Installer-'+[guid]::NewGuid().ToString('N'))))
$app=Join-Path $root 'Приложение с пробелами'
$stage=Join-Path $root 'payload'
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$msiexec=Join-Path $env:SystemRoot 'System32\msiexec.exe'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName='NextDNS Connection Manager'
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBefore=(Get-FileHash -LiteralPath $hosts).Hash
$dnsBefore=Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress
$proxyBefore=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object AutoConfigURL,ProxyEnable,ProxyServer|ConvertTo-Json -Compress
function Get-MsiCode([string]$Path) {
 $installer=$null;$database=$null;$view=$null;$record=$null
 try {
  $installer=New-Object -ComObject WindowsInstaller.Installer
  $database=$installer.OpenDatabase($Path,0)
  $view=$database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductCode'")
  $view.Execute();$record=$view.Fetch();$code=$record.StringData(1)
  return $code
 } finally {
  if($view){$view.Close()}
  foreach($com in @($record,$view,$database,$installer)){if($com){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com)}}
 }
}
$productCode=Get-MsiCode $SetupPath
function Run-Msi([string]$Arguments,[string]$Log) {
 $p=Start-Process -FilePath $msiexec -ArgumentList ($Arguments+' /qn /norestart /l*v "'+(Join-Path $root $Log)+'"') -Wait -PassThru
 if($p.ExitCode -ne 0 -and (Test-Path -LiteralPath (Join-Path $root $Log))){
  Get-Content -LiteralPath (Join-Path $root $Log)|Select-String -Pattern 'WixQuietExec|Return value 3|Error |error |Exception' -Context 1,2|Select-Object -Last 20|ForEach-Object {Write-Host $_}
 }
 return $p.ExitCode
}
function Run-Setup([string]$Log,[switch]$Repair) {
 $arguments='/i "'+$SetupPath+'" INSTALLFOLDER="'+$app+'"'
 if($Repair){$arguments+=' REINSTALL=ALL REINSTALLMODE=amus'}
 Run-Msi $arguments $Log
}
try {
 New-Item -ItemType Directory -Path $root|Out-Null
 [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath,$stage)
 if((Run-Setup 'install.log') -ne 0){throw 'Fresh installation failed'}
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $stage 'GeoRoute') -Recurse -File){
  $relative=$file.FullName.Substring((Join-Path $stage 'GeoRoute').Length+1)
  if($relative -in @('_service\profiles.json','_service\connection-routes.json') -or $relative.StartsWith('_service\profiles\')){$relative=$relative.Replace('_service\','_service\defaults\')}
  if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $app $relative)).Hash){throw ('Installed payload differs: '+$relative)}
 }
 $shortcutPath=Join-Path ([Environment]::GetFolderPath('Programs')) 'GeoRoute.lnk'
 if(-not(Test-Path -LiteralPath $shortcutPath)){throw 'Start menu shortcut missing'}
 $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
 $linkFolder=(New-Object -ComObject Shell.Application).NameSpace((Split-Path $shortcutPath -Parent))
 $linkArguments=$linkFolder.ParseName('GeoRoute.lnk').ExtendedProperty('System.Link.Arguments')
 if($shortcut.TargetPath -ine $shell -or $linkArguments -notlike ('*"'+$app+'\_service\NextDNS-GUI.ps1"')){throw ('Shortcut mismatch: '+$shortcut.TargetPath+'; '+$linkArguments)}
 $smoke=Start-Process -FilePath $shortcut.TargetPath -ArgumentList ($linkArguments+' -SmokeTest') -WindowStyle Hidden -Wait -PassThru
 if($smoke.ExitCode -ne 0){throw 'Installed shortcut GUI smoke failed'}
 if($ScreenshotDirectory){
  New-Item -ItemType Directory -Path $ScreenshotDirectory -Force|Out-Null
  $preview=Join-Path $ScreenshotDirectory 'georoute.png'
  $render=Start-Process -FilePath $shell -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $app '_service\NextDNS-GUI.ps1')+'" -RenderPreview -PreviewPath "'+$preview+'"') -WindowStyle Hidden -Wait -PassThru
  if($render.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $preview)){throw 'Installed GUI screenshot export failed'}
 }
 $mutex=[Threading.Mutex]::new($false,('Global\GeoRoute.Setup.Application.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
 try {if((Run-Setup 'running.log' -Repair) -eq 0){throw 'Installer replaced a running app'}}finally{$mutex.Dispose()}
 $catalog=Join-Path $app '_service\profiles.json';$routes=Join-Path $app '_service\connection-routes.json'
 Add-Content -LiteralPath $catalog -Value ' ';Add-Content -LiteralPath $routes -Value ' '
 $profile=Join-Path $app '_service\profiles\primary.hosts';Add-Content -LiteralPath $profile -Value '# preservation test'
 $custom=Join-Path $app '_service\profiles\user-test.hosts';[IO.File]::WriteAllText($custom,'# user profile')
 $prefs=Join-Path $app '_service\GUI-settings.json';[IO.File]::WriteAllText($prefs,'{"reducedMotion":true}')
 $keep=@($catalog,$routes,$profile,$custom,$prefs)
 $hashes=@{};foreach($file in $keep){$hashes[$file]=(Get-FileHash -LiteralPath $file).Hash}
 if((Run-Setup 'repair.log' -Repair) -ne 0){throw 'Update/repair failed'}
 foreach($file in $keep){if((Get-FileHash -LiteralPath $file).Hash -ne $hashes[$file]){throw ('Update lost data: '+$file)}}
 # Build the next version from the same verified payload solely as an upgrade fixture.
 $match=[regex]::Match([IO.Path]::GetFileName($SetupPath),'-(\d+)\.(\d+)\.(\d+)-x64\.msi$')
 if(-not $match.Success){throw 'Unexpected setup version filename'}
 $next=$match.Groups[1].Value+'.'+$match.Groups[2].Value+'.'+([int]$match.Groups[3].Value+1)
 $fixture=Join-Path $root 'upgrade-fixture'
 & (Join-Path (Split-Path $PSScriptRoot -Parent) 'Build-Installer.ps1') -Version $next -ArchivePath $ArchivePath -OutputDirectory $fixture
 $upgrade=Join-Path $fixture ('GeoRoute-Setup-'+$next+'-x64.msi')
 $entry=Join-Path $app 'GeoRoute.cmd'
 Add-Content -LiteralPath $entry -Value 'rem upgrade replacement check'
 if((Run-Msi ('/i "'+$upgrade+'" INSTALLFOLDER="'+$app+'"') 'major-upgrade.log') -ne 0){throw 'Major version upgrade failed'}
 $productCode=Get-MsiCode $upgrade
 foreach($file in $keep){if((Get-FileHash -LiteralPath $file).Hash -ne $hashes[$file]){throw ('Major upgrade lost data: '+$file)}}
 if((Get-FileHash -LiteralPath $entry).Hash -ne (Get-FileHash -LiteralPath (Join-Path $stage 'GeoRoute\GeoRoute.cmd')).Hash){throw 'Major upgrade did not replace code'}
 New-Item -Path $runKey -Force|Out-Null
 New-ItemProperty -Path $runKey -Name $runName -Value 'unrelated-startup-test' -Force|Out-Null
 if((Run-Msi ('/x '+$productCode) 'uninstall.log') -ne 0 -or (Test-Path -LiteralPath (Join-Path $app 'GeoRoute.cmd'))){throw 'Uninstall failed'}
 if((Get-ItemPropertyValue -LiteralPath $runKey -Name $runName) -ne 'unrelated-startup-test'){throw 'Uninstall removed unrelated startup'}
 foreach($file in $keep){if((Get-FileHash -LiteralPath $file).Hash -ne $hashes[$file]){throw ('Uninstall lost data: '+$file)}}
 Remove-ItemProperty -LiteralPath $runKey -Name $runName
 if((Run-Setup 'reinstall.log') -ne 0){throw 'Reinstall failed'}
 $productCode=Get-MsiCode $SetupPath
 $own='"'+$env:ComSpec+'" /d /s /c ""'+(Join-Path $app 'GeoRoute.cmd')+'" -Tray"'
 New-ItemProperty -Path $runKey -Name $runName -Value $own -Force|Out-Null
 if((Run-Msi ('/x '+$productCode) 'uninstall-owned.log') -ne 0){throw 'Second uninstall failed'}
 if(Get-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue){throw 'Dangling startup value'}
 # A fully removed data folder must not leave MSI component markers that break reinstall.
 if(-not $app.StartsWith(($root+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected app data path'}
 Remove-Item -LiteralPath $app -Recurse -Force
 if((Run-Setup 'clean-reinstall.log') -ne 0){throw 'Clean reinstall failed'}
 $cleanSmoke=Start-Process -FilePath $shell -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+(Join-Path $app '_service\NextDNS-GUI.ps1')+'" -SmokeTest') -WindowStyle Hidden -Wait -PassThru
 if($cleanSmoke.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $catalog)){throw 'Profile defaults did not recover after clean reinstall'}
 if((Run-Msi ('/x '+$productCode) 'clean-uninstall.log') -ne 0){throw 'Clean uninstall failed'}
 if($CheckDefaultLocation){
  $defaultApp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\GeoRoute'
  if(Test-Path -LiteralPath $defaultApp){throw 'Unexpected existing default install folder on disposable runner'}
  try {
   if((Run-Msi ('/i "'+$SetupPath+'"') 'default-install.log') -ne 0){throw 'Default-location install failed'}
   $defaultGui=Join-Path $defaultApp '_service\NextDNS-GUI.ps1'
   if(-not(Test-Path -LiteralPath $defaultGui)){throw 'Default install used an unexpected location'}
   foreach($directory in @([Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('Desktop'))){
    $link=Join-Path $directory 'GeoRoute.lnk'
    if(-not(Test-Path -LiteralPath $link)){throw ('Missing installed shortcut: '+$link)}
    $folder=(New-Object -ComObject Shell.Application).NameSpace($directory)
    $arguments=$folder.ParseName('GeoRoute.lnk').ExtendedProperty('System.Link.Arguments')
    if($arguments -notlike ('*"'+$defaultGui+'"')){throw 'Default install shortcut points outside app'}
   }
   # Verify the entry actually consumed by Windows Settings / Installed apps.
   $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$productCode
   $registration=Get-ItemProperty -LiteralPath $uninstallKey
   if($registration.DisplayName -ne 'GeoRoute' -or $registration.WindowsInstaller -ne 1 -or
      $registration.UninstallString -notlike ('*'+$productCode+'*')){throw 'Installed-apps registration mismatch'}
   $defaultSmoke=Start-Process -FilePath $shell -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "'+$defaultGui+'" -SmokeTest') -WindowStyle Hidden -Wait -PassThru
   if($defaultSmoke.ExitCode -ne 0){throw 'Default install GUI smoke failed'}
  } finally {if((Run-Msi ('/x '+$productCode) 'default-uninstall.log') -ne 0){throw 'Default install cleanup failed'}}
  if(Test-Path -LiteralPath $uninstallKey){throw 'Uninstall left an installed-apps entry'}
 }
 if((Get-FileHash -LiteralPath $hosts).Hash -ne $hostsBefore){throw 'Installer changed hosts'}
 if((Get-DnsClientServerAddress|ConvertTo-Json -Depth 5 -Compress) -cne $dnsBefore){throw 'Installer changed DNS'}
 $proxyAfter=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'|Select-Object AutoConfigURL,ProxyEnable,ProxyServer|ConvertTo-Json -Compress
 if($proxyAfter -cne $proxyBefore){throw 'Installer changed proxy'}
 Write-Output 'MSI passed: exact payload, Cyrillic path, shortcut GUI, running-app guard, real version upgrade, profile preservation, clean reinstall, uninstall, owned startup and untouched network.'
 if($CheckDefaultLocation){Write-Output 'Published MSI also passed: standard per-user folder, desktop and Start menu shortcuts, installed-apps registration/removal and default-location GUI launch.'}
} catch {
 Write-Host ('Installer integration failed: '+$_.Exception.Message)
 throw
} finally {
 if(-not $root.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP)+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -notmatch '^GeoRoute-Installer-[a-f0-9]{32}$'){throw 'Unexpected integration-test path'}
 if(Test-Path -LiteralPath $root){try{Remove-Item -LiteralPath $root -Recurse -Force}catch{Write-Warning ('Disposable runner cleanup: '+$_.Exception.Message)}}
}
