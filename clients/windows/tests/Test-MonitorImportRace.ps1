#Requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Get-TaskImage($Name){return $null}
function Get-TaskBrush($Color){return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)}
function Update-GeoEditorState{}
$script:raceScanRequests=0
function Start-GeoMonitor {param([switch]$Refresh) $script:raceScanRequests++;throw 'Unexpected network scan'}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'NextDNS-GUI.ps1'),[ref]$tokens,[ref]$parseErrors)
$busy=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-TaskBusy'},$true)
Invoke-Expression $busy.Extent.Text
[xml]$xaml=Get-Content (Join-Path $source 'Window.xaml') -Raw -Encoding UTF8
$reader=[Xml.XmlNodeReader]::new($xaml)
try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
$script:taskUi=@{}
foreach($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')){
    $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if($name){$script:taskUi[$name]=$window.FindName($name)}
}
foreach($page in @('HomePage','OverviewPage','ServersPage','JournalPage','SettingsPage','DnsMonitorPage')){$window.FindName($page).Visibility='Collapsed'}
$script:taskUi.GeoPage.Visibility='Visible'
$script:taskProfiles=@();$script:taskProfileControls=@{};$script:taskSelectedProfileId=''
$script:taskHealthRun=$null;$script:taskCleanupRun=$null;$script:taskReducedMotion=$true
$script:geoRegionFilter='ALL';$script:geoHistory=@{};$script:taskRoot=$source
$SmokeTest=$true;$RenderPreview=$false
Set-GeoMonitoringMinutes 0
function Layout {
    $root=$window.Content;$root.Width=1220;$root.Height=910
    $root.Measure([Windows.Size]::new(1220,910));$root.Arrange([Windows.Rect]::new(0,0,1220,910));$root.UpdateLayout()
    $root.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $root.UpdateLayout()
}
function Find-ConnectButton($Root){
    if($Root -is [Windows.Controls.Button] -and $Root.Tag -eq 'GeoConnect'){return $Root}
    for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$i++){
        $found=Find-ConnectButton ([Windows.Media.VisualTreeHelper]::GetChild($Root,$i))
        if($found){return $found}
    }
}
function Complete-TestMonitor {
    $process=[pscustomobject]@{Disposed=$false}
    $process|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $script:geoRun=[pscustomobject]@{Process=$process}
    Complete-GeoMonitor
    Assert $process.Disposed 'Real monitor completion disposes its worker'
}
try {
    $report=New-GeoPendingReport @([pscustomobject]@{region='EU';address='143.20.64.192'}) 'import-race'
    Set-TaskBusy $true
    $report.running=$false;$report.completed=1
    $row=$report.rows[0];$row.CheckState='Complete';$row.CheckedAt=(Get-Date).ToString('o')
    $row.TCP=$true;$row.TLS=$true;$row.HTTP=200;$row.Country='NL';$row.LatencyMs=10
    $row.EligibleEU=$true;$row.FilesTLS=$true;$row.FilesHTTP=404;$row.GeminiReady=$true
    $row.GeminiVerificationTLS=$true;$row.GeminiVerificationHTTP=429
    Update-GeoRows $report
    Complete-TestMonitor
    Layout
    $button=Find-ConnectButton $script:taskUi.GeoGrid
    Assert ($null -ne $button -and -not $button.IsEnabled) 'Actual WPF button stays disabled while import is busy'
    Set-TaskBusy $false
    Layout
    $button=Find-ConnectButton $script:taskUi.GeoGrid
    Assert $button.IsEnabled 'Finishing import must immediately enable a ready node after monitor completion'
    Poll-GeoMonitor
    Assert ($script:raceScanRequests -eq 0 -and (Get-GeoMonitoringMinutes) -eq 0) 'Never requires no extra scan to restore the button'

    # Reverse event order: finishing import must not unlock an unfinished scan.
    Set-TaskBusy $true;$report.running=$true;Update-GeoRows $report
    Set-TaskBusy $false;Layout
    Assert (-not (Find-ConnectButton $script:taskUi.GeoGrid).IsEnabled) 'Import completion cannot unlock a still-running monitor'
    $report.running=$false;Update-GeoRows $report;Complete-TestMonitor;Layout
    Assert (Find-ConnectButton $script:taskUi.GeoGrid).IsEnabled 'A later monitor completion enables the ready row'

    # Global busy transitions must not override a row failure or stale result.
    foreach($failure in @('files','stale','retired')){
        $row.FilesHTTP=404;$row.CheckedAt=(Get-Date).ToString('o');$row.SourceActive=$true
        switch($failure){files{$row.FilesHTTP=503}stale{$row.CheckedAt=(Get-Date).AddDays(-1).ToString('o')}retired{$row.SourceActive=$false}}
        Set-TaskBusy $true;Update-GeoRows $report;Complete-TestMonitor;Set-TaskBusy $false;Layout
        Assert (-not (Find-ConnectButton $script:taskUi.GeoGrid).IsEnabled) ('Busy completion preserves '+$failure+' rejection')
    }
    Assert ($script:raceScanRequests -eq 0) 'No network scan was launched'
    Write-Output 'WPF monitor/import race passed: both completion orders, Never, inherited busy gate and rejected rows; no network requests.'
}finally{$window.Close()}
