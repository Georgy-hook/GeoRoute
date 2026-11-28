#Requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'QuickStart.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Click($Button){$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function Get-GuideText($Node){if($Node -is [Windows.Controls.TextBlock]){$Node};for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$i++){Get-GuideText ([Windows.Media.VisualTreeHelper]::GetChild($Node,$i))}}
$window=New-GeoQuickStart $root
try{
 Assert ($window.Tag.Steps.Count -eq 4 -and $window.Tag.Index -eq 0) 'Guide starts at the first of four steps'
 Assert (-not $window.FindName('GuideBack').IsEnabled) 'Back is disabled at start'
 foreach($size in @(@(660,680),@(460,420))){
  for($index=0;$index -lt 4;$index++){
   $window.Tag.Index=$index;Update-GeoQuickStart $window
   $window.Content.Measure([Windows.Size]::new($size[0],$size[1]));$window.Content.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]));$window.Content.UpdateLayout()
   $next=$window.FindName('GuideNext');$position=$next.TranslatePoint([Windows.Point]::new(0,0),$window.Content)
   $tasks=@(Get-GuideText ($window.FindName('GuideTasks'))|Where-Object {$_.Text -in $window.Tag.Steps[$index].Tasks})
   Assert ($tasks.Count -eq $window.Tag.Steps[$index].Tasks.Count) 'All instructions are realized'
   foreach($task in $tasks){Assert ($task.TextWrapping -eq 'Wrap' -and $task.ActualWidth -le $size[0]-56) 'Instructions wrap inside the viewport instead of clipping';if($size[0] -eq 460 -and $task.Text.Length -gt 95){Assert ($task.ActualHeight -gt 22) 'Long instructions occupy multiple lines at compact width'}}
   Assert ($next.ActualWidth -ge 160 -and $position.X -ge 0 -and $position.X+$next.ActualWidth -le $size[0] -and $position.Y+$next.ActualHeight -le $size[1]) 'Navigation stays visible at compact and normal sizes'
  }
 }
 $window.Tag.Index=0;Update-GeoQuickStart $window
 Click $window.FindName('GuideNext');Assert ($window.Tag.Index -eq 1 -and $window.FindName('GuideCounter').Text -eq '2 из 4') 'Next updates the visible step'
 Click $window.FindName('GuideBack');Assert ($window.Tag.Index -eq 0) 'Back returns to previous step'
 for($index=0;$index -lt 4;$index++){Click $window.FindName('GuideNext')}
 Assert ($window.Tag.Target -eq 'Home') 'Guide returns to the connection screen without connecting or changing settings'
 $allText=(@($window.Tag.Steps|ForEach-Object {$_.Title;$_.Summary;$_.Tasks;$_.Note}) -join ' ')
 Assert ($allText -match 'WARP' -and $allText -match 'Автоподключение' -and $allText -match 'Сайты и DNS' -and $allText -match 'GeoRoute.cmd') 'Portable, opt-in WARP, selected sites and launch are explained'
 Write-Output 'Quick start: four real WPF steps, next/back, compact layout and navigation-only completion passed; no windows displayed or network changes.'
}finally{$window.Close()}
