#Requires -Version 5.1
param([string]$ScreenshotDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
function Get-TaskImage($Name){return $null}
function Get-TaskBrush($Color){return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)}
function Assert($Value,$Message){if(-not $Value){throw $Message}}
[xml]$xml=[IO.File]::ReadAllText((Join-Path $source 'Window.xaml'))
$reader=[Xml.XmlNodeReader]::new($xml)
try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
$script:taskUi=@{}
foreach($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$script:taskUi[$name]=$window.FindName($name)}}
$script:taskRoot=$source;$script:geoRegionFilter='ALL';$SmokeTest=$true;$RenderPreview=$false
$script:geoHistory=@{}
$now=[DateTimeOffset]::Now.AddMinutes(-1)
try {
    $empty=Get-GeoHistoryView @()
    Assert ($empty.Count -eq 'Проверок пока нет' -and $empty.Visual.Children.Count -eq 0) 'Empty history cannot look like a failed check'
    $legacy=@(0..29|ForEach-Object {[pscustomobject]@{at=$now.AddHours($_-30).ToString('o');ok=($_%3 -ne 0);tcp=($_%3 -ne 0);ms=250}})
    $legacy+=@([pscustomobject]@{at='broken';ok=$false;tcp=$false;ms=0})
    $legacy+=@([pscustomobject]@{at=$now.AddHours(-1).ToUniversalTime().ToString('o');ok=$true;tcp=$true;ms=250})
    $script:geoHistory['EU-143.20.64.192']=$legacy
    $report=New-GeoPendingReport @([pscustomobject]@{region='EU';address='143.20.64.192'}) 'history-fixture'
    $report.running=$false;$report.completed=1
    $row=$report.rows[0];$row.CheckState='Complete';$row.CheckedAt=$now.ToString('o');$row.TCP=$true;$row.TLS=$false
    $row.Error='TLS failed: '+('unabridged diagnostic details '*20)
    Update-GeoHistory $report
    $item=$script:geoDisplayRows[0]
    $samples=@($script:geoHistory['EU-143.20.64.192'])
    Assert ($samples.Count -eq 24 -and $item.Bars.Count -eq 24) 'Keep 24 genuine timestamps, deduplicate equivalent offsets and discard corrupt dates'
    Assert ($item.HistoryCount -match 'из 24 успешно' -and $item.HistoryLast -eq ('Последняя: '+$now.ToLocalTime().ToString('dd.MM, HH:mm'))) 'Count and exact local date/time are always visible'
    Assert ($item.HistoryHint.Contains($now.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss')) -and $item.HistoryHint.Contains('Период:')) 'Tooltip identifies the actual date range and each check time'
    Assert ($item.ReasonLabel -eq 'Ошибка HTTPS' -and $item.ReasonHint.Contains($row.Error) -and $samples[-1].reason -eq 'Ошибка HTTPS') 'Readable reason retains the entire technical diagnosis and is stored for future history'
    Update-GeoHistory $report
    Assert (@($script:geoHistory['EU-143.20.64.192']).Count -eq 24) 'Repainting cannot count a check twice'
    $row.Error='TLS timeout';Update-GeoHistory $report
    Assert ($script:geoDisplayRows[0].ReasonLabel -eq 'Тайм-аут HTTPS') 'Timeout has a short explicit explanation'
    $row.TLS=$true;$row.HTTP=403;Update-GeoHistory $report
    Assert ($script:geoDisplayRows[0].ReasonLabel -eq 'HTTP 403 · доступ запрещён') 'HTTP refusal is not mislabeled as a network failure'
    $row.TLS=$false;$row.HTTP=$null;$row.Error='TLS failed: '+('full technical details '*20);Update-GeoHistory $report
    foreach($page in @('HomePage','OverviewPage','ServersPage','JournalPage','SettingsPage')){$script:taskUi[$page].Visibility='Collapsed'}
    $script:taskUi.GeoPage.Visibility='Visible';Initialize-GeoMonitorLayout
    $historyColumn=@($script:taskUi.GeoGrid.Columns|Where-Object Header -eq 'История ChatGPT')[0]
    function Find-Texts($Root){
        if($Root -is [Windows.Controls.TextBlock]){Write-Output $Root}
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$i++){Find-Texts ([Windows.Media.VisualTreeHelper]::GetChild($Root,$i))}
    }
    foreach($size in @(@(980,640),@(1920,1040))){
        $width=$size[0];$height=$size[1];$root=$window.Content
        $root.Width=$width;$root.Height=$height
        for($pass=0;$pass -lt 3;$pass++){$root.Measure([Windows.Size]::new($width,$height));$root.Arrange([Windows.Rect]::new(0,0,$width,$height));$root.UpdateLayout();Update-GeoMonitorLayout}
        $container=$script:taskUi.GeoGrid.ItemContainerGenerator.ContainerFromIndex(0)
        $cell=$historyColumn.GetCellContent($container)
        $texts=@(Find-Texts $cell)
        foreach($value in @($script:geoDisplayRows[0].HistoryCount,$script:geoDisplayRows[0].HistoryLast)){
            $text=@($texts|Where-Object Text -eq $value)[0]
            Assert ($text -and $text.ActualWidth -ge $text.DesiredSize.Width-$text.Margin.Left-$text.Margin.Right-1 -and $text.ActualHeight -ge $text.DesiredSize.Height-$text.Margin.Top-$text.Margin.Bottom-1) ('History text must fit at '+$width+': '+$value+'; actual='+$text.ActualWidth+'x'+$text.ActualHeight+'; desired='+$text.DesiredSize)
        }
        if($ScreenshotDirectory){
            [IO.Directory]::CreateDirectory($ScreenshotDirectory)|Out-Null
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($root)
            $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory ('history-'+$width+'.png')));try{$encoder.Save($stream)}finally{$stream.Dispose()}
        }
    }
    Write-Output 'History passed: legacy and corrupt data, 24-check retention, time zones, deduplication, human reasons, complete diagnostics and actual WPF text at narrow/wide sizes; no network requests.'
} finally {$window.Close()}
