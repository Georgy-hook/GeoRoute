$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-monitor-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'geohide-servers.json') -Destination $temp
    $script:taskRoot=$temp;$script:taskShell='fake';$SmokeTest=$false;$RenderPreview=$false
    $script:taskUi=@{}
    foreach($name in @('GeoCheck','GeoRefresh','GeoAdd','GeoProgressPanel','GeoStatus')){$script:taskUi[$name]=[pscustomobject]@{IsEnabled=$true;Content='';Visibility='Collapsed';Text=''}}
    $script:launches=0;$script:failLaunch=$false
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
        $script:launches++
        $script:lastLaunchArguments=$ArgumentList
        if($script:failLaunch){throw 'Simulated start failure'}
        $p=[pscustomobject]@{HasExited=$false;ExitCode=0;Killed=$false;Disposed=$false}
        $p|Add-Member ScriptMethod Kill {$this.Killed=$true}
        $p|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        return $p
    }
    function Update-GeoRows($Report){$script:geoReport=$Report}
    function Update-GeoHistory($Report){}
    function Update-GeoEditorState{}
    Start-GeoMonitor
    Assert ($script:launches -eq 1 -and -not $script:taskUi.GeoCheck.IsEnabled -and -not $script:taskUi.GeoRefresh.IsEnabled) 'Both launch buttons disabled immediately'
    Assert ($script:taskUi.GeoProgressPanel.Visibility -eq 'Visible' -and $script:geoReport.rows.Count -gt 0) 'Global loading and all queued rows exist before worker output'
    Start-GeoMonitor -Refresh
    Assert ($script:launches -eq 1) 'Repeated click cannot create another worker'
    $id=$script:geoRun.Id
    $old=New-GeoPendingReport @([pscustomobject]@{region='US';address='192.255.159.240'}) 'old-run'
    Write-GeoJson $script:geoRun.Path $old
    Poll-GeoMonitor
    Assert ($script:geoReport.runId -eq $id) 'Previous run output is ignored'
    $current=New-GeoPendingReport @([pscustomobject]@{region='EU';address='37.221.93.128'}) $id
    $current.rows[0].CheckState='Complete';$current.rows[0].CheckedAt=(Get-Date).ToString('o');$current.running=$false;$current.completed=1
    Write-GeoJson $script:geoRun.Path $current
    $script:geoRun.Process.HasExited=$true
    Poll-GeoMonitor
    Assert (-not $script:geoRun -and $script:taskUi.GeoCheck.IsEnabled -and $script:taskUi.GeoProgressPanel.Visibility -eq 'Collapsed') 'Completion unlocks controls and hides global loading'
    Assert ($script:geoReport.completed -eq 1) 'Final result is consumed on process exit'
    $before=$script:launches
    $script:geoAt=(Get-Date).AddMinutes(-119);$script:geoSourceAt=(Get-Date).AddMinutes(-119)
    Poll-GeoMonitor
    Assert ($script:launches -eq $before) 'No automatic probe before two hours'
    $script:geoAt=(Get-Date).AddMinutes(-121);$script:geoSourceAt=(Get-Date).AddMinutes(-121)
    Poll-GeoMonitor
    Assert ($script:launches -eq $before+1 -and '-RefreshSources' -in $script:lastLaunchArguments) 'Two-hour scan also refreshes the provider lists'
    Complete-GeoMonitor
    Poll-GeoMonitor
    Assert ($script:launches -eq $before+1) 'Completion starts a new two-hour cooldown'
    $script:failLaunch=$true
    Start-GeoMonitor
    Assert ($script:taskUi.GeoCheck.IsEnabled -and -not $script:geoRun) 'Start failure restores controls'
    Assert (-not @( $script:geoReport.rows|Where-Object {Test-GeoPendingRow $_}).Count) 'Start failure clears every row indicator'
    $script:failLaunch=$false
    Start-GeoMonitor
    $script:geoRun.At=(Get-Date).AddSeconds(-601)
    Poll-GeoMonitor
    Assert (-not $script:geoRun -and $script:taskUi.GeoCheck.IsEnabled) 'Timeout unlocks controls'
    Assert (@($script:geoReport.rows|Where-Object CheckState -eq 'Interrupted').Count -gt 0) 'Unfinished probes remain explicitly interrupted, not healthy'

    Start-GeoMonitor
    [IO.File]::WriteAllText($script:geoRun.Path,'{malformed')
    $script:geoRun.Process.HasExited=$true;$script:geoRun.Process.ExitCode=1
    Poll-GeoMonitor
    Assert (-not $script:geoRun -and $script:taskUi.GeoCheck.IsEnabled) 'Malformed output from a failed worker cannot leave loading stuck'

    # Exercise real WPF row projection: queued rows must not become failed history samples.
    Add-Type -AssemblyName PresentationFramework
    . (Join-Path $source 'GeoHideHistory.ps1')
    function Get-TaskImage($Name){return $null}
    function Get-TaskBrush($Color){return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)}
    foreach($name in @('GeoCountUS','GeoCountEU','GeoCountRU','GeoSearch','GeoGrid','GeoFilterALL','GeoFilterUS','GeoFilterEU','GeoFilterRU')){$script:taskUi[$name]=[pscustomobject]@{Text='';ItemsSource=$null;Background=$null}}
    $script:geoRegionFilter='ALL';$SmokeTest=$true
    $pending=New-GeoPendingReport @([pscustomobject]@{region='EU';address='37.221.93.128'}) 'history'
    Update-GeoHistory $pending
    Assert ($script:geoDisplayRows[0].LoadingVisibility -eq 'Visible') 'Actual row projection exposes loading indicator'
    Assert (@($script:geoHistory['EU-37.221.93.128']).Count -eq 0) 'Queued rows never record a synthetic failure'
    Stop-GeoReportLoading $pending
    Update-GeoHistory $pending
    Assert ($script:geoDisplayRows[0].LoadingVisibility -eq 'Collapsed') 'Interrupted row stops loading'
    Assert (@($script:geoHistory['EU-37.221.93.128']).Count -eq 0) 'Interrupted rows never record a synthetic failure'
    Write-Output 'Monitor lifecycle passed: duplicate launch, stale run, final report, start failure, timeout, row loading and real history projection.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-monitor-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
