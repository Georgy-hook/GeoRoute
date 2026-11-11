#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'Connection.ps1')
. (Join-Path $root 'BrowserRecovery.ps1')
$script:passed=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message};$script:passed++}
$all=@(1..4 | ForEach-Object {[pscustomobject]@{State='ready'}})
Assert ((New-ConnectionReport $all).State -eq 'ready') 'Full DNS match'
Assert (-not (New-ConnectionReport $all).AttachmentsVerified) 'DNS is not attachment evidence'
Assert ((New-ConnectionReport @()).State -eq 'unavailable') 'Empty probe must not be green'
Assert ((New-ConnectionReport $all[0..2]).State -eq 'unavailable') 'Partial probe must not be green'
Assert ((New-ConnectionReport @($all+$all+$all+$all[0]) -ExpectedCount 13).State -eq 'ready') 'Expanded route catalogs use their actual requirement count'
Assert ((New-ConnectionReport $all -ExpectedCount 13).State -eq 'unavailable') 'A partial expanded catalog is not green'
Assert (Test-ConnectionHostsMode '# BEGIN CHATGPT-US-WINDOWS' $true) 'Managed hosts remain authoritative when Bridge runs'
Assert (Test-ConnectionHostsMode '# END CHATGPT-US-WINDOWS' $true) 'Damaged managed markers are diagnosed by the hosts reader'
Assert (Test-ConnectionHostsMode '' $false) 'Disabled Bridge retains hosts diagnostics'
Assert (-not (Test-ConnectionHostsMode '' $true)) 'DNS-only mode still checks NextDNS routing rules'
$workerTemp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-worker-'+[guid]::NewGuid().ToString('N'))
$workerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try{
 [IO.Directory]::CreateDirectory((Join-Path $workerTemp 'System32\drivers\etc'))|Out-Null
 foreach($name in @('ConnectionWorker.ps1','Connection.ps1','Home.ps1','GeoServices.ps1')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $workerTemp}
 [IO.File]::WriteAllText((Join-Path $workerTemp 'GeoHide.ps1'),'. (Join-Path $PSScriptRoot ''GeoServices.ps1'')')
 [IO.File]::WriteAllText((Join-Path $workerTemp 'HttpProxy.ps1'),"function Get-HttpProxyState { [pscustomobject]@{Enabled=`$false} }`r`nfunction Get-Service { [pscustomobject]@{Status='Running'} }")
 [IO.File]::WriteAllText((Join-Path $workerTemp 'System32\drivers\etc\hosts'),"# BEGIN CHATGPT-US-WINDOWS`r`n192.0.2.1 chatgpt.com`r`n# END CHATGPT-US-WINDOWS`r`n")
 $workerResult=Join-Path $workerTemp 'result.json'
 [IO.File]::WriteAllText((Join-Path $workerTemp 'run-worker.ps1'),@'
function Get-Content {
 param([string]$LiteralPath,[switch]$Raw,[string]$Encoding,[string]$ErrorAction)
 if($LiteralPath -eq (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')){
  $PSBoundParameters['LiteralPath']=Join-Path $PSScriptRoot 'System32\drivers\etc\hosts'
 }
 Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
& (Join-Path $PSScriptRoot 'ConnectionWorker.ps1') -ResultPath (Join-Path $PSScriptRoot 'result.json')
exit $LASTEXITCODE
'@)
 & $workerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workerTemp 'run-worker.ps1')
 Assert ($LASTEXITCODE -eq 0) 'Actual hosts worker exits successfully with a running Bridge'
 $workerReport=Get-Content -LiteralPath $workerResult -Raw|ConvertFrom-Json
 Assert ($workerReport.Mode -eq 'hosts' -and $workerReport.State -eq 'checking' -and -not $workerReport.AttachmentsVerified) 'Actual worker reports hosts status without inventing network success'
}finally{
 $full=[IO.Path]::GetFullPath($workerTemp)
 if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-worker-[a-f0-9]{32}$'){throw 'Unsafe worker cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
$all[2].State='unavailable'
Assert ((New-ConnectionReport $all).State -eq 'unavailable') 'Timeout must not be green'
$all[1].State='mismatch'
Assert ((New-ConnectionReport $all).State -eq 'mismatch') 'Changed route must be visible'

# Replace external boundaries; no real browser is closed or started by this test.
$script:fake=@();$script:closed=0;$script:starts=@();$script:command='chrome.exe --profile-directory="Profile 1"';$script:binary='C:\test\chrome.exe'
function Get-RecoveryChromeProcesses {return $script:fake}
function Get-ManagerChrome {return 'C:\test\chrome.exe'}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{CommandLine=$script:command;ExecutablePath=$script:binary}}
function Start-Process {param($FilePath,$ArgumentList) $script:starts+=@{File=$FilePath;Args=$ArgumentList}}
function MustThrow([scriptblock]$Action,[string]$Hint) {$caught=$false;try{& $Action}catch{$caught=$_.Exception.Message -like ('*'+$Hint+'*')};Assert $caught $Hint}
MustThrow {Start-BrowserRecovery} 'уже закрыт'
$proc=[pscustomobject]@{Id=1;MainWindowHandle=[IntPtr]101}
$proc|Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {$script:closed++;return $false}
$script:fake=@($proc);$script:command='chrome.exe --user-data-dir="C:\isolated"'
MustThrow {Start-BrowserRecovery} 'отдельной папкой'
Assert ($script:closed -eq 0) 'Custom profile is untouched'
$script:binary='C:\other\chrome.exe'
MustThrow {Start-BrowserRecovery} 'другой папки'
Assert ($script:closed -eq 0) 'Other browser installation is untouched'
$script:binary='C:\test\chrome.exe'
$script:command='chrome.exe --profile-directory="Profile 1"'
$run=Start-BrowserRecovery
Assert ($script:closed -eq 1) 'Normal close requested once'
Assert ($run.Profiles[0] -eq 'Profile 1') 'Explicit profile preserved'
$result=Update-BrowserRecovery $run
Assert (-not $result.Done -and $script:closed -eq 1) 'Do not repeatedly close a confirmation window'
$run.At=(Get-Date).AddSeconds(-30)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and -not $result.Success -and $script:starts.Count -eq 0) 'Blocked close never reports success or starts another session'
$script:fake=@();$run.At=Get-Date
$result=Update-BrowserRecovery $run
Assert (-not $result.Done -and $script:starts.Count -eq 1 -and $script:starts[0].Args -contains '--restore-last-session') 'Open only after complete exit'
Assert ($script:starts[0].Args -contains '--profile-directory="Profile 1"') 'Restore requested profile'
$script:fake=@($proc)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and $result.Success) 'Report observed new window'
Assert ($result.Message -like '*GIF ещё не проверено*') 'Restart is not GIF verification'
$script:fake=@();$run.At=(Get-Date).AddSeconds(-20)
$result=Update-BrowserRecovery $run
Assert ($result.Done -and -not $result.Success) 'Missing new window is not success'
Write-Output ('Passed '+$script:passed+' connection/recovery checks; no browser or system settings changed.')
