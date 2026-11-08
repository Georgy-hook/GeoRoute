$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'DnsMonitorUI.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Get-TaskImage($Name){return $null}
$root=Join-Path ([IO.Path]::GetTempPath()) ('georoute-dns-monitor-'+[guid]::NewGuid().ToString('N'))
try{
 [IO.Directory]::CreateDirectory((Join-Path $root 'bridge\python'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $root 'bridge\python\python.exe'),'test placeholder, never executed')
 Copy-Item (Join-Path $source 'dns-providers.json') $root
 $script:taskRoot=$root;$SmokeTest=$false;$RenderPreview=$false;$script:taskBusy=$false;$script:launches=0
 $script:taskUi=@{}
 foreach($n in @('DnsMonitorCheck','DnsMonitorProgress','DnsMonitorStatus','DnsMonitorUse','DnsMonitorSelected','DnsMonitorSearch','DnsMonitorGrid')){$script:taskUi[$n]=[pscustomobject]@{IsEnabled=$true;Content='';Visibility='Collapsed';Text='';ItemsSource=$null;SelectedItem=$null}}
 function Start-Process {
  param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
  $script:launches++
  $p=[pscustomobject]@{HasExited=$false;ExitCode=0;Killed=$false}
  $p|Add-Member ScriptMethod Kill {$this.Killed=$true}
  $p|Add-Member ScriptMethod Dispose {}
  return $p
 }
 Start-DnsMonitor;Start-DnsMonitor
 Assert ($script:launches -eq 1 -and -not $script:taskUi.DnsMonitorCheck.IsEnabled) 'Duplicate scans must be blocked'
 Assert (@($script:taskUi.DnsMonitorGrid.ItemsSource|Where-Object Loading -eq 'Visible').Count -gt 0) 'Pending provider rows must expose loading state'
 $good=[pscustomobject]@{id='good';name='Good';url='https://dns.google/dns-query';servers=@('8.8.8.8');state='complete';ready=$true;at=(Get-Date).ToString('o');ms=20;error=''}
 $report=[pscustomobject]@{runId='old-run';rows=@($good);running=$false;completed=1;total=1;at=(Get-Date).ToString('o')}
 $report|ConvertTo-Json -Depth 6|Set-Content $script:dnsMonitorRun.Path -Encoding UTF8
 Poll-DnsMonitor
 Assert ($script:dnsMonitorReport.rows.Count -gt 1) 'Stale run output cannot replace the active scan'
 $report.runId=$script:dnsMonitorRun.Id
 $report|ConvertTo-Json -Depth 6|Set-Content $script:dnsMonitorRun.Path -Encoding UTF8
 $script:dnsMonitorRun.Process.HasExited=$true
 Poll-DnsMonitor
 Assert ($script:taskUi.DnsMonitorCheck.IsEnabled -and -not $script:dnsMonitorRun) 'Completion must unlock scan controls'
 $selected=Get-DnsMonitorSelection $good
 Assert ($selected.url -eq $good.url -and $selected.servers[0] -eq '8.8.8.8') 'Selection retains the checked provider and bootstrap address'
 $good.at=(Get-Date).AddMinutes(-6).ToString('o')
 Assert (-not(Test-DnsMonitorFresh $good)) 'Old healthy answers cannot unlock provider selection'
 $rejected=$false;try{Get-DnsMonitorSelection $good|Out-Null}catch{$rejected=$true};Assert $rejected 'Stale selection must be rejected'
 Start-DnsMonitor;$script:dnsMonitorRun.At=(Get-Date).AddSeconds(-151)
 Poll-DnsMonitor
 Assert (-not $script:dnsMonitorRun -and $script:taskUi.DnsMonitorCheck.IsEnabled) 'Timeout must unlock scan controls'
 Assert (@($script:dnsMonitorReport.rows|Where-Object state -eq 'interrupted').Count -gt 0) 'Unfinished DNS rows must not be recorded as failed checks'
 Write-Output 'DNS monitor passed: loading, duplicate guard, run ownership, freshness, selection and timeout; network unchanged.'
}finally{
 Stop-DnsMonitor
 $path=[IO.Path]::GetFullPath($root)
 if(-not $path.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notmatch '^georoute-dns-monitor-[a-f0-9]{32}$'){throw 'Unexpected test path'}
 if(Test-Path $path){Remove-Item -LiteralPath $path -Recurse -Force}
}
